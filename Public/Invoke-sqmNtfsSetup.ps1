<#
.SYNOPSIS
Grants the SQL Server service accounts NTFS permissions on the instance's data, log, TempDB
and backup directories (with an ACL backup beforehand).

.DESCRIPTION
Reproduces the manual "set NTFS permissions after install" step in an auditable way:

  1. Determines the SQL Server service accounts (Engine + Agent) for the instance via
     Get-DbaService (or uses -Account when supplied).
  2. Determines the relevant directories automatically: the instance default Data/Log/Backup
     paths (Get-DbaDefaultPath) plus every directory that currently holds a database file
     (sys.master_files, which covers Data, Log and TempDB) - or uses -Directory when supplied.
  3. Writes a backup of the current ACLs (SDDL per directory) to a timestamped JSON file under
     -BackupPath, unless -SkipBackup is set. This allows manual rollback.
  4. Grants each service account the requested rights (FullControl by default, inherited to
     sub-folders and files) on each directory.

Filesystem changes are applied locally, so this is intended to run on the SQL Server itself
(as the SQL Setup tool does). Every change honours -WhatIf / -Confirm.

If SqlInstance is not specified, the current computer name ($env:COMPUTERNAME) is used.

.PARAMETER SqlInstance
The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE"). Default: current computer name.

.PARAMETER SqlCredential
Alternative credentials (PSCredential) for the SQL connection. Default: Windows authentication.

.PARAMETER Account
One or more accounts to grant permissions to. Default: auto-discovered SQL Engine/Agent service accounts.

.PARAMETER Directory
One or more directories to set permissions on. Default: auto-discovered Data/Log/TempDB/Backup directories.

.PARAMETER Permission
NTFS rights to grant: 'FullControl' (default) or 'Modify'.

.PARAMETER BackupPath
Directory for the ACL backup file. Default: the configured OutputPath (Get-sqmConfig).

.PARAMETER SkipBackup
Skip writing the ACL backup file. Not recommended.

.PARAMETER EnableException
Propagate exceptions immediately instead of logging them as warnings and returning a status object.

.EXAMPLE
Invoke-sqmNtfsSetup -SqlInstance "SQL01"
Auto-discovers the service accounts and SQL directories and grants FullControl.

.EXAMPLE
Invoke-sqmNtfsSetup -SqlInstance "SQL01\INST01" -Permission Modify -WhatIf
Shows which accounts would get Modify on which directories, without changing anything.

.EXAMPLE
Invoke-sqmNtfsSetup -Directory 'E:\MSSQL\DATA','F:\MSSQL\LOG' -Account 'NT SERVICE\MSSQLSERVER'
Sets permissions only on the given directories for the given account.

.NOTES
Requires the dbatools module and the Invoke-sqmLogging function. Run on the SQL Server host.
Default for SqlInstance: $env:COMPUTERNAME (applies to all future versions).
#>

function Invoke-sqmNtfsSetup
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$Account,
		[Parameter(Mandatory = $false)]
		[string[]]$Directory,
		[Parameter(Mandatory = $false)]
		[ValidateSet('FullControl', 'Modify')]
		[string]$Permission = 'FullControl',
		[Parameter(Mandatory = $false)]
		[string]$BackupPath,
		[Parameter(Mandatory = $false)]
		[switch]$SkipBackup,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
			Write-Verbose "Keine SqlInstance angegeben. Verwende Standard: $SqlInstance"
		}

		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren Sie es mit: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		if ([string]::IsNullOrWhiteSpace($BackupPath))
		{
			$BackupPath = Get-sqmConfig -Key 'OutputPath'
			if ([string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath = Get-sqmConfig -Key 'LogPath' }
		}

		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		Invoke-sqmLogging -Message "Starte $functionName auf Instanz: $SqlInstance (Permission: $Permission)" -FunctionName $functionName -Level "INFO"
	}

	process
	{
		$result = [PSCustomObject]@{
			SqlInstance = $SqlInstance
			Accounts    = @()
			Directories = @()
			Permission  = $Permission
			BackupFile  = $null
			Granted     = @()
			Status      = 'Unknown'
			Message     = $null
		}

		try
		{
			# --- 1. Dienstkonten ermitteln ---------------------------------------------
			if ($Account)
			{
				$accounts = @($Account)
			}
			else
			{
				$computer = ($SqlInstance -split '\\')[0]
				if ($computer -in @('.', 'localhost', '(local)')) { $computer = $env:COMPUTERNAME }
				$instName = if ($SqlInstance -match '\\') { ($SqlInstance -split '\\')[1] } else { 'MSSQLSERVER' }

				$services = Get-DbaService -ComputerName $computer -Type Engine, Agent -ErrorAction Stop
				$accounts = @($services | Where-Object { $_.InstanceName -eq $instName } |
					Select-Object -ExpandProperty StartName -Unique)
				if (-not $accounts)
				{
					$accounts = @($services | Select-Object -ExpandProperty StartName -Unique)
				}
			}
			$accounts = @($accounts | Where-Object { $_ })
			if (-not $accounts)
			{
				$errMsg = "Keine SQL-Dienstkonten gefunden fuer '$SqlInstance'. Bitte -Account angeben."
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$result.Status = 'NoAccounts'; $result.Message = $errMsg
				if ($EnableException) { throw $errMsg }
				return $result
			}
			$result.Accounts = $accounts
			Invoke-sqmLogging -Message "Dienstkonten: $($accounts -join ', ')" -FunctionName $functionName -Level "INFO"

			# --- 2. Verzeichnisse ermitteln --------------------------------------------
			if ($Directory)
			{
				$dirs = @($Directory)
			}
			else
			{
				$dirs = @()
				try
				{
					$dp = Get-DbaDefaultPath @connParams -ErrorAction Stop
					$dirs += @($dp.Data, $dp.Log, $dp.Backup)
				}
				catch { Write-Verbose "Get-DbaDefaultPath fehlgeschlagen: $($_.Exception.Message)" }

				$files = Invoke-DbaQuery @connParams -Database master `
					-Query "SELECT DISTINCT physical_name FROM sys.master_files" -ErrorAction Stop
				$dirs += @($files | ForEach-Object { Split-Path $_.physical_name -Parent })
			}
			# normalisieren, deduplizieren, nur existierende Verzeichnisse
			$dirs = @($dirs | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') } |
				Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
			if (-not $dirs)
			{
				$errMsg = "Keine gueltigen Verzeichnisse gefunden fuer '$SqlInstance'. Bitte -Directory angeben."
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$result.Status = 'NoDirectories'; $result.Message = $errMsg
				if ($EnableException) { throw $errMsg }
				return $result
			}
			$result.Directories = $dirs
			Invoke-sqmLogging -Message "Verzeichnisse: $($dirs -join ', ')" -FunctionName $functionName -Level "INFO"

			# --- 3. ACL-Backup ----------------------------------------------------------
			if (-not $SkipBackup)
			{
				try
				{
					if (-not (Test-Path -LiteralPath $BackupPath -PathType Container))
					{
						New-Item -ItemType Directory -Path $BackupPath -Force -ErrorAction Stop | Out-Null
					}
					$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
					$safeInst = ($SqlInstance -replace '[\\\/:]', '_')
					$backupFile = Join-Path $BackupPath "NtfsAclBackup_${safeInst}_$stamp.json"
					$snapshot = foreach ($d in $dirs) { [PSCustomObject]@{ Path = $d; Sddl = (Get-Acl -LiteralPath $d).Sddl } }
					$snapshot | ConvertTo-Json -Depth 3 | Out-File -FilePath $backupFile -Encoding UTF8 -ErrorAction Stop
					$result.BackupFile = $backupFile
					Invoke-sqmLogging -Message "ACL-Backup geschrieben: $backupFile" -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$errMsg = "ACL-Backup fehlgeschlagen: $($_.Exception.Message). Abbruch (keine Berechtigungen geaendert)."
					Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
					$result.Status = 'BackupFailed'; $result.Message = $errMsg
					if ($EnableException) { throw $errMsg }
					return $result
				}
			}

			# --- 4. Berechtigungen vergeben --------------------------------------------
			$rights = [System.Security.AccessControl.FileSystemRights]$Permission
			$inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
			$prop = [System.Security.AccessControl.PropagationFlags]::None
			$granted = @()
			$failed = @()

			foreach ($dir in $dirs)
			{
				foreach ($acct in $accounts)
				{
					$action = "Grant $Permission to '$acct'"
					if ($PSCmdlet.ShouldProcess($dir, $action))
					{
						try
						{
							$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($acct, $rights, $inherit, $prop, 'Allow')
							$acl = Get-Acl -LiteralPath $dir
							$acl.AddAccessRule($rule)
							Set-Acl -LiteralPath $dir -AclObject $acl -ErrorAction Stop
							$granted += "$acct -> $dir"
							Invoke-sqmLogging -Message "$Permission fuer '$acct' auf '$dir' vergeben." -FunctionName $functionName -Level "INFO"
						}
						catch
						{
							$failed += "$acct -> $dir : $($_.Exception.Message)"
							Invoke-sqmLogging -Message "Fehler bei '$acct' auf '$dir': $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
						}
					}
					else
					{
						Invoke-sqmLogging -Message "WhatIf: $Permission fuer '$acct' auf '$dir' wuerde vergeben." -FunctionName $functionName -Level "VERBOSE"
					}
				}
			}

			$result.Granted = $granted

			if ($failed.Count -gt 0)
			{
				$result.Status = if ($granted.Count -gt 0) { 'PartialFailure' } else { 'Failed' }
				$result.Message = "Fehler bei $($failed.Count) Zuweisung(en): " + ($failed -join ' | ')
				if ($EnableException) { throw $result.Message }
			}
			elseif ($granted.Count -gt 0)
			{
				$result.Status = 'Granted'
				$result.Message = "$($granted.Count) Berechtigung(en) erfolgreich vergeben."
			}
			else
			{
				$result.Status = 'WhatIfSkipped'
				$result.Message = "WhatIf: $($accounts.Count) Konto(en) wuerden $Permission auf $($dirs.Count) Verzeichnis(se) erhalten."
			}
		}
		catch
		{
			$errMsg = "Fehler in $functionName`: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			$result.Status = 'Failed'
			$result.Message = $errMsg
			if ($EnableException) { throw }
		}

		return $result
	}

	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
	}
}
