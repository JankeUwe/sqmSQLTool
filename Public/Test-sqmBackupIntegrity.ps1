<#
.SYNOPSIS
    Verifies one or more backup files using RESTORE VERIFYONLY.

.DESCRIPTION
    Executes RESTORE VERIFYONLY on a backup file (local or optionally remote).
    Returns $true if the check was successful, otherwise $false.
    Can verify multiple files in sequence (e.g. stripes).

.PARAMETER SqlInstance
    SQL Server instance on which the verification runs (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER BackupPath
    Path to the backup file (.bak) on the server (local path, not UNC). Can be an array.
    If not specified, the directory from the module configuration (BackupDirectory) is used.
    Fallback: the default backup directory of the target SQL Server instance.

.PARAMETER FileListOnly
    When $true, only lists the files contained in the backup (without VerifyOnly).

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Test-sqmBackupIntegrity -SqlInstance "SQL01" -BackupPath "D:\Backup\AdventureWorks.bak"

.NOTES
    Uses Restore-DbaDatabase with the -VerifyOnly parameter.
#>
function Test-sqmBackupIntegrity
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$BackupPath,
		[Parameter(Mandatory = $false)]
		[switch]$FileListOnly,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		# BackupPath: wenn nicht angegeben ? Config ? SQL Server Default
		if (-not $PSBoundParameters.ContainsKey('BackupPath') -or -not $BackupPath)
		{
			$cfgPath = Get-sqmConfig -Key 'BackupDirectory' 3>$null
			if (-not [string]::IsNullOrWhiteSpace($cfgPath))
			{
				Invoke-sqmLogging -Message "BackupPath aus Konfiguration: $cfgPath" -FunctionName $functionName -Level "INFO"
				$BackupPath = @($cfgPath)
			}
			else
			{
				# Fallback: SQL Server-Standardbackupverzeichnis der Instanz
				try
				{
					$regQuery = @"
DECLARE @BackupDirectory NVARCHAR(4000);
EXEC master.dbo.xp_instance_regread
    N'HKEY_LOCAL_MACHINE',
    N'SOFTWARE\Microsoft\MSSQLServer\MSSQLServer',
    N'BackupDirectory',
    @BackupDirectory OUTPUT;
SELECT @BackupDirectory AS BackupDirectory;
"@
					$regResult = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
						-Query $regQuery -ErrorAction Stop
					if ($regResult.BackupDirectory)
					{
						Invoke-sqmLogging -Message "BackupPath aus SQL Server Registry: $($regResult.BackupDirectory)" -FunctionName $functionName -Level "INFO"
						$BackupPath = @($regResult.BackupDirectory)
					}
				}
				catch { }
			}
		}

		if (-not $BackupPath)
		{
			$errMsg = "Kein BackupPath angegeben und kein 'BackupDirectory' in Konfiguration oder SQL Server Registry gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance  - $($BackupPath.Count) Pfad/e" -FunctionName $functionName -Level "INFO"
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
	}
	
	process
	{
		foreach ($file in $BackupPath)
		{
			try
			{
				if ($FileListOnly)
				{
					$fileList = Restore-DbaDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Path $file -FileListOnly -ErrorAction Stop
					foreach ($f in $fileList)
					{
						$allResults.Add([PSCustomObject]@{
								BackupFile  = $file
								LogicalName = $f.LogicalName
								PhysicalName = $f.PhysicalName
								Type	    = $f.Type
								FileGroupName = $f.FileGroupName
								SizeMB	    = [math]::Round($f.Size/1024, 2)
							})
					}
				}
				else
				{
					Invoke-sqmLogging -Message "Verifiziere Backup: $file" -FunctionName $functionName -Level "INFO"
					$null = Restore-DbaDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Path $file -VerifyOnly -EnableException -ErrorAction Stop
					$allResults.Add([PSCustomObject]@{
							BackupFile = $file
							Verified   = $true
							Message    = "RESTORE VERIFYONLY erfolgreich."
						})
				}
			}
			catch
			{
				$errMsg = "Fehler bei $file : $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw }
				$allResults.Add([PSCustomObject]@{
						BackupFile = $file
						Verified   = $false
						Message    = $errMsg
					})
			}
		}
		return $allResults
	}
}