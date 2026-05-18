function Invoke-sqmMonitoringKey
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[Alias('Computer', 'Server')]
		[string[]]$ComputerName = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[ValidateSet('Get', 'Set')]
		[string]$Operation = 'Get',
		[Parameter(Mandatory = $false)]
		[ValidateSet('None', 'Standard', 'Full')]
		[string]$SQL,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Standard', 'Cluster')]
		[string]$SQLFreeSpaceVersion,
		[Parameter(Mandatory = $false)]
		[ValidateSet(0, 1)]
		[Nullable[int]]$TSM,
		[Parameter(Mandatory = $false)]
		[string]$RegistryBase = 'System',
		[Parameter(Mandatory = $false)]
		[switch]$AutoDetectSQLFreeSpaceVersion,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$Credential,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$regSubKey = "$RegistryBase\FITS\SystemCenter"
		$regPath = "HKLM:\$regSubKey"
		
		$sqlToDword = @{ 'None' = 0; 'Standard' = 1; 'Full' = 2 }
		$sqlDesc = @{ 0 = 'NoMonitoring'; 1 = 'ServiceMonitoring'; 2 = 'FullMonitoring' }
		$tsmDesc = @{ 0 = 'Inactive'; 1 = 'Active' }
		
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
	}
	
	process
	{
		foreach ($computer in $ComputerName)
		{
			try
			{
				Invoke-sqmLogging -Message "[$computer] Operation: $Operation" -FunctionName $functionName -Level "INFO"
				
				$effectiveFreeSpaceVersion = $SQLFreeSpaceVersion
				
				# AutoDetect (nur bei Set)
				if ($Operation -eq 'Set' -and $AutoDetectSQLFreeSpaceVersion -and [string]::IsNullOrWhiteSpace($effectiveFreeSpaceVersion))
				{
					Invoke-sqmLogging -Message "[$computer] AutoDetect SQLFreeSpaceVersion ..." -FunctionName $functionName -Level "INFO"
					try
					{
						if (-not (Get-Module -ListAvailable -Name dbatools))
						{
							Invoke-sqmLogging -Message "dbatools nicht gefunden - AutoDetect uebersprungen, verwende 'Standard'." -FunctionName $functionName -Level "WARNING"
							$effectiveFreeSpaceVersion = 'Standard'
						}
						else
						{
							$agCheck = Get-DbaAvailabilityGroup -SqlInstance $computer -ErrorAction SilentlyContinue
							$effectiveFreeSpaceVersion = if ($agCheck) { 'Cluster' }
							else { 'Standard' }
							Invoke-sqmLogging -Message "[$computer] AutoDetect Ergebnis: $effectiveFreeSpaceVersion" -FunctionName $functionName -Level "INFO"
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "[$computer] AutoDetect fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
						$effectiveFreeSpaceVersion = 'Standard'
					}
				}
				
				# Schreibvorgang
				if ($Operation -eq 'Set')
				{
					if ([string]::IsNullOrWhiteSpace($SQL) -and [string]::IsNullOrWhiteSpace($effectiveFreeSpaceVersion) -and $null -eq $TSM)
					{
						Invoke-sqmLogging -Message "[$computer] Keine Werte zum Setzen angegeben." -FunctionName $functionName -Level "WARNING"
						continue
					}
					
					if ($PSCmdlet.ShouldProcess($computer, "Setze Monitoring-Registry-Werte in '$regPath'"))
					{
						# Stelle sicher, dass der Schluessel existiert (lokal/remote)
						$keyExists = $false
						try
						{
							if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost' -or $computer -eq '.')
							{
								$fullPath = "HKLM:\$regSubKey"
								if (-not (Test-Path $fullPath))
								{
									New-Item -Path $fullPath -Force -ErrorAction Stop | Out-Null
									Invoke-sqmLogging -Message "[$computer] Registry-Schluessel erstellt: $fullPath" -FunctionName $functionName -Level "INFO"
								}
								$keyExists = $true
							}
							else
							{
								# Remote: Pruefe/Erstelle ueber Invoke-Command
								$sb = {
									param ($sk)
									$fullPath = "HKLM:\$sk"
									if (-not (Test-Path $fullPath))
									{
										New-Item -Path $fullPath -Force -ErrorAction Stop | Out-Null
										Write-Output "CREATED"
									}
									else
									{
										Write-Output "EXISTS"
									}
								}
								$invokeParams = @{
									ComputerName = $computer
									ScriptBlock  = $sb
									ArgumentList = $regSubKey
									ErrorAction  = 'Stop'
								}
								if ($Credential) { $invokeParams['Credential'] = $Credential }
								$result = Invoke-Command @invokeParams
								if ($result -eq 'CREATED')
								{
									Invoke-sqmLogging -Message "[$computer] Registry-Schluessel remote erstellt: HKLM:\$regSubKey" -FunctionName $functionName -Level "INFO"
								}
								$keyExists = $true
							}
						}
						catch
						{
							Invoke-sqmLogging -Message "[$computer] Fehler bei Schluesselerstellung: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
							throw
						}
						
						# Nun Werte setzen
						$values = @{ }
						if (-not [string]::IsNullOrWhiteSpace($SQL)) { $values['SQL'] = $sqlToDword[$SQL] }
						if (-not [string]::IsNullOrWhiteSpace($effectiveFreeSpaceVersion)) { $values['SQLFreeSpaceVersion'] = $effectiveFreeSpaceVersion }
						if ($null -ne $TSM) { $values['TSM'] = [int]$TSM }
						
						if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost' -or $computer -eq '.')
						{
							$fullPath = "HKLM:\$regSubKey"
							foreach ($entry in $values.GetEnumerator())
							{
								$type = if ($entry.Value -is [int]) { 'DWord' }
								else { 'String' }
								Set-ItemProperty -Path $fullPath -Name $entry.Key -Value $entry.Value -Type $type -ErrorAction Stop
							}
						}
						else
						{
							$sb2 = {
								param ($sk,
									$vals)
								$fullPath = "HKLM:\$sk"
								foreach ($entry in $vals.GetEnumerator())
								{
									$type = if ($entry.Value -is [int]) { 'DWord' }
									else { 'String' }
									Set-ItemProperty -Path $fullPath -Name $entry.Key -Value $entry.Value -Type $type -ErrorAction Stop
								}
								return $true
							}
							$invokeParams2 = @{
								ComputerName = $computer
								ScriptBlock  = $sb2
								ArgumentList = $regSubKey, $values
								ErrorAction  = 'Stop'
							}
							if ($Credential) { $invokeParams2['Credential'] = $Credential }
							Invoke-Command @invokeParams2 | Out-Null
						}
						Invoke-sqmLogging -Message "[$computer] Werte erfolgreich gesetzt." -FunctionName $functionName -Level "INFO"
					}
					else
					{
						Invoke-sqmLogging -Message "[$computer] WhatIf: Schreibvorgang uebersprungen." -FunctionName $functionName -Level "VERBOSE"
					}
				}
				
				# Lesen (immer, auch nach Set)
				# Hier wird der Schluessel NICHT erstellt - nur lesen
				$current = $null
				try
				{
					if ($computer -eq $env:COMPUTERNAME -or $computer -eq 'localhost' -or $computer -eq '.')
					{
						$fullPath = "HKLM:\$regSubKey"
						if (Test-Path $fullPath)
						{
							$key = Get-ItemProperty -Path $fullPath -ErrorAction Stop
							$current = @{
								SQL = $key.SQL
								SQLFreeSpaceVersion = $key.SQLFreeSpaceVersion
								TSM = $key.TSM
								_KeyExists = $true
							}
						}
						else
						{
							$current = @{ _KeyExists = $false }
						}
					}
					else
					{
						$sbRead = {
							param ($sk)
							$fullPath = "HKLM:\$sk"
							if (Test-Path $fullPath)
							{
								$key = Get-ItemProperty -Path $fullPath -ErrorAction Stop
								return @{
									SQL = $key.SQL
									SQLFreeSpaceVersion = $key.SQLFreeSpaceVersion
									TSM = $key.TSM
									_KeyExists = $true
								}
							}
							else
							{
								return @{ _KeyExists = $false }
							}
						}
						$invokeRead = @{
							ComputerName = $computer
							ScriptBlock  = $sbRead
							ArgumentList = $regSubKey
							ErrorAction  = 'Stop'
						}
						if ($Credential) { $invokeRead['Credential'] = $Credential }
						$current = Invoke-Command @invokeRead
					}
				}
				catch
				{
					throw "Registry-Lesen fehlgeschlagen: $($_.Exception.Message)"
				}
				
				$status = if ($Operation -eq 'Set') { if ($current._KeyExists) { 'Updated' }
					else { 'Created' } }
				elseif ($current._KeyExists) { 'OK' }
				else { 'KeyNotFound' }
				
				$sqlVal = $current.SQL
				$tsmVal = $current.TSM
				$fsvVal = $current.SQLFreeSpaceVersion
				$sqlText = if ($null -ne $sqlVal -and $sqlDesc.ContainsKey([int]$sqlVal)) { $sqlDesc[[int]$sqlVal] }
				else { '(nicht gesetzt)' }
				$tsmText = if ($null -ne $tsmVal -and $tsmDesc.ContainsKey([int]$tsmVal)) { $tsmDesc[[int]$tsmVal] }
				else { '(nicht gesetzt)' }
				
				$msg = switch ($status)
				{
					'KeyNotFound' { "Registry-Schluessel '$regPath' nicht vorhanden." }
					'Created'     { "Schluessel neu erstellt und Werte gesetzt." }
					'Updated'     { "Werte aktualisiert." }
					default       { "Werte erfolgreich ausgelesen." }
				}
				
				$allResults.Add([PSCustomObject]@{
						ComputerName = $computer
						RegistryPath = "HKLM:\$regSubKey"
						SQL		     = $sqlVal
						SQL_Description = $sqlText
						SQLFreeSpaceVersion = $fsvVal
						TSM		     = $tsmVal
						TSM_Description = $tsmText
						Status	     = $status
						Message	     = $msg
					})
			}
			catch
			{
				$errMsg = $_.Exception.Message
				Invoke-sqmLogging -Message "[$computer] Fehler: $errMsg" -FunctionName $functionName -Level "ERROR"
				$allResults.Add([PSCustomObject]@{
						ComputerName = $computer
						RegistryPath = "HKLM:\$regSubKey"
						SQL		     = $null
						SQL_Description = '(Fehler)'
						SQLFreeSpaceVersion = $null
						TSM		     = $null
						TSM_Description = '(Fehler)'
						Status	     = 'Failed'
						Message	     = $errMsg
					})
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw }
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
		return $allResults
	}
}