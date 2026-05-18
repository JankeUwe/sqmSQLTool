<#
.SYNOPSIS
    Prueft eine oder mehrere Backup?Dateien mit RESTORE VERIFYONLY.

.DESCRIPTION
    Fuehrt RESTORE VERIFYONLY auf einer Backup?Datei (lokal oder optional remote) aus.
    Liefert $true, wenn die Pruefung erfolgreich war, sonst $false.
    Kann mehrere Dateien nacheinander pruefen (z.B. Stripes).

.PARAMETER SqlInstance
    SQL Server-Instanz, auf der der Verifizierungslauf erfolgt (Standard: aktueller Computername).

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER BackupPath
    Pfad zur Backup?Datei (.bak) auf dem Server (lokaler Pfad, kein UNC). Kann Array sein.
    Wenn nicht angegeben, wird das Verzeichnis aus der Modulkonfiguration (BackupDirectory) verwendet.
    Fallback: SQL Server Standardbackup-Verzeichnis der Zielinstanz.

.PARAMETER FileListOnly
    Wenn $true, wird nur die Liste der enthaltenen Dateien angezeigt (ohne VerifyOnly).

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.EXAMPLE
    Test-sqmBackupIntegrity -SqlInstance "SQL01" -BackupPath "D:\Backup\AdventureWorks.bak"

.NOTES
    Verwendet Restore-DbaDatabase mit Parameter -VerifyOnly.
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