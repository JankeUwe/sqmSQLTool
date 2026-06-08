<#
.SYNOPSIS
Grants SELECT, INSERT, and UPDATE permissions on master.dbo.sqm_BackupExclude to a login.

.DESCRIPTION
Ensures that the specified Windows group or SQL login has the necessary permissions
to read and modify the backup exclude table master.dbo.sqm_BackupExclude.

The function performs the following steps:
  1. Verifies that master.dbo.sqm_BackupExclude exists — if not, an error is thrown
     with the hint to run Sync-sqmBackupExcludeTable first.
  2. Checks whether the login already exists on the SQL Server instance.
     If not, it is created automatically via New-DbaLogin.
  3. Ensures the login has a corresponding database user in master.
     If not, the user is created via New-DbaDbUser.
  4. Grants SELECT, INSERT, and UPDATE on master.dbo.sqm_BackupExclude to the user.

If SqlInstance is not specified, the current computer name ($env:COMPUTERNAME) is used.

.PARAMETER SqlInstance
The target SQL Server instance (e.g. "localhost", "SQL01\INSTANCE").
If not specified, the current computer name is used.

.PARAMETER SqlCredential
Alternative credentials (PSCredential). If not specified, Windows authentication is used.

.PARAMETER LoginName
The Windows group (e.g. "DOMAIN\DBA-Team") or SQL login to grant permissions to.
This parameter is mandatory.

.PARAMETER EnableException
Switch to propagate exceptions immediately (by default errors are logged as warnings).

.EXAMPLE
# Grant permissions to a Windows group on the local instance
Set-sqmBackupExcludePermission -LoginName "CONTOSO\DBA-Team"

.EXAMPLE
# Grant permissions to a SQL login on a remote instance
Set-sqmBackupExcludePermission -SqlInstance "SQL01" -LoginName "svc_backup"

.EXAMPLE
# Preview what would happen without making any changes
Set-sqmBackupExcludePermission -SqlInstance "SQL01" -LoginName "CONTOSO\DBA-Team" -WhatIf

.NOTES
Requires the dbatools module and the Invoke-sqmLogging function.
The table master.dbo.sqm_BackupExclude must exist before calling this function.
Run Sync-sqmBackupExcludeTable first if the table does not yet exist.
Default for SqlInstance: $env:COMPUTERNAME (applies to all future versions).
#>

function Set-sqmBackupExcludePermission
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[string]$LoginName,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		# Default fuer SqlInstance: aktueller Computername
		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
			Write-Verbose "Keine SqlInstance angegeben. Verwende Standard: $SqlInstance"
		}

		# Pruefung auf dbatools
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			$errMsg = "dbatools-Modul nicht gefunden. Bitte installieren Sie es mit: Install-Module dbatools"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		Invoke-sqmLogging -Message "Starte $functionName auf Instanz: $SqlInstance fuer Login: $LoginName" -FunctionName $functionName -Level "INFO"

		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		$tableName   = 'master.dbo.sqm_BackupExclude'
		$permissions = 'SELECT, INSERT, UPDATE'
	}

	process
	{
		$result = [PSCustomObject]@{
			SqlInstance = $SqlInstance
			LoginName   = $LoginName
			TableName   = $tableName
			Permissions = $permissions
			Status      = 'Unknown'
			Message     = $null
		}

		try
		{
			# 1. Tabelle pruefen
			$tableCheck = Invoke-DbaQuery @connParams -Database master `
				-Query "SELECT 1 AS TableExists FROM sys.objects WHERE object_id = OBJECT_ID(N'master.dbo.sqm_BackupExclude') AND type = 'U'" `
				-ErrorAction Stop

			if (-not $tableCheck)
			{
				$errMsg = "Tabelle $tableName existiert nicht auf '$SqlInstance'. Bitte zuerst Sync-sqmBackupExcludeTable ausfuehren."
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$result.Status  = 'TableMissing'
				$result.Message = $errMsg
				if ($EnableException) { throw $errMsg }
				return $result
			}

			Invoke-sqmLogging -Message "Tabelle $tableName gefunden." -FunctionName $functionName -Level "INFO"

			# 2. Login auf dem Server pruefen / erstellen
			$existingLogin = Get-DbaLogin @connParams -Login $LoginName -ErrorAction SilentlyContinue

			if (-not $existingLogin)
			{
				$actionMsg = "Erstelle Login '$LoginName' auf '$SqlInstance'"
				if ($PSCmdlet.ShouldProcess($SqlInstance, $actionMsg))
				{
					Invoke-sqmLogging -Message "Login '$LoginName' nicht gefunden. Wird erstellt." -FunctionName $functionName -Level "INFO"
					New-DbaLogin @connParams -Login $LoginName -ErrorAction Stop | Out-Null
					Invoke-sqmLogging -Message "Login '$LoginName' erfolgreich erstellt." -FunctionName $functionName -Level "INFO"
				}
				else
				{
					Invoke-sqmLogging -Message "WhatIf: Login '$LoginName' wuerde erstellt werden." -FunctionName $functionName -Level "VERBOSE"
					$result.Status  = 'WhatIfSkipped'
					$result.Message = "WhatIf: Login '$LoginName' wuerde erstellt und Berechtigungen wuerden vergeben werden."
					return $result
				}
			}
			else
			{
				Invoke-sqmLogging -Message "Login '$LoginName' ist bereits auf dem Server vorhanden." -FunctionName $functionName -Level "INFO"
			}

			# 3. Datenbankbenutzer in master pruefen / erstellen
			$existingUser = Get-DbaDbUser @connParams -Database master -User $LoginName -ErrorAction SilentlyContinue

			if (-not $existingUser)
			{
				$actionMsg = "Erstelle Datenbankbenutzer '$LoginName' in master"
				if ($PSCmdlet.ShouldProcess("master", $actionMsg))
				{
					Invoke-sqmLogging -Message "Datenbankbenutzer '$LoginName' in master nicht gefunden. Wird erstellt." -FunctionName $functionName -Level "INFO"
					New-DbaDbUser @connParams -Database master -Login $LoginName -ErrorAction Stop | Out-Null
					Invoke-sqmLogging -Message "Datenbankbenutzer '$LoginName' in master erstellt." -FunctionName $functionName -Level "INFO"
				}
				else
				{
					Invoke-sqmLogging -Message "WhatIf: Datenbankbenutzer '$LoginName' wuerde in master erstellt werden." -FunctionName $functionName -Level "VERBOSE"
					$result.Status  = 'WhatIfSkipped'
					$result.Message = "WhatIf: Datenbankbenutzer '$LoginName' wuerde erstellt und Berechtigungen wuerden vergeben werden."
					return $result
				}
			}
			else
			{
				Invoke-sqmLogging -Message "Datenbankbenutzer '$LoginName' ist bereits in master vorhanden." -FunctionName $functionName -Level "INFO"
			}

			# 4. Berechtigungen vergeben
			$grantSql    = "GRANT SELECT, INSERT, UPDATE ON master.dbo.sqm_BackupExclude TO [$($LoginName.Replace(']', ']]'))];"
			$actionMsg   = "Vergebe $permissions auf $tableName fuer '$LoginName'"

			if ($PSCmdlet.ShouldProcess($LoginName, $actionMsg))
			{
				Invoke-sqmLogging -Message $actionMsg -FunctionName $functionName -Level "INFO"
				Invoke-DbaQuery @connParams -Database master -Query $grantSql -ErrorAction Stop
				$successMsg = "Berechtigung '$permissions' auf $tableName erfolgreich fuer '$LoginName' vergeben."
				Invoke-sqmLogging -Message $successMsg -FunctionName $functionName -Level "INFO"
				$result.Status  = 'Granted'
				$result.Message = $successMsg
			}
			else
			{
				Invoke-sqmLogging -Message "WhatIf: '$permissions' wuerde auf $tableName fuer '$LoginName' vergeben werden." -FunctionName $functionName -Level "VERBOSE"
				$result.Status  = 'WhatIfSkipped'
				$result.Message = "WhatIf: Berechtigung '$permissions' wuerde auf $tableName fuer '$LoginName' vergeben werden."
			}
		}
		catch
		{
			$errMsg = "Fehler in $functionName`: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			$result.Status  = 'Failed'
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
