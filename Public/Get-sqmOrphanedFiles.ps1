<#
.SYNOPSIS
    Findet MDF/LDF/NDF-Datenbankdateien, die keiner Datenbank zugeordnet sind.

.DESCRIPTION
    Liest alle registrierten Datenbankdateien aus sys.master_files und vergleicht
    diese mit den tatsaechlich vorhandenen Dateien in den Verzeichnissen.
    Dateien die auf dem Dateisystem existieren, aber nicht in sys.master_files
    eingetragen sind, werden als verwaist (Orphaned) gemeldet.

    Hinweis: Die Verzeichnisse werden von der PowerShell-Session aus durchsucht.
    Bei Remote-Instanzen muessen die Pfade als UNC-Pfade erreichbar sein oder
    SearchPath explizit als UNC-Pfad angegeben werden.

.PARAMETER SqlInstance
    SQL Server-Instanz. Standard: lokaler Computername.

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER SearchPath
    Verzeichnisse, die durchsucht werden sollen.
    Standard: alle eindeutigen Verzeichnisse aus sys.master_files + SQL Server Standardpfade.

.PARAMETER FileExtension
    Dateierweiterungen die gesucht werden.
    Standard: .mdf, .ldf, .ndf

.PARAMETER Recurse
    Unterverzeichnisse rekursiv durchsuchen.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.EXAMPLE
    Get-sqmOrphanedFiles -SqlInstance "SQL01"

.EXAMPLE
    Get-sqmOrphanedFiles -SqlInstance "SQL01" -SearchPath "D:\SQLData","E:\SQLLog" -Recurse

.NOTES
    Erfordert: dbatools, Invoke-sqmLogging
    Benoetigt VIEW SERVER STATE und Dateisystemzugriff auf die Datenbankverzeichnisse.
#>
function Get-sqmOrphanedFiles
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string[]]$SearchPath,
		[Parameter(Mandatory = $false)]
		[string[]]$FileExtension = @('.mdf', '.ldf', '.ndf'),
		[Parameter(Mandatory = $false)]
		[switch]$Recurse,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
		}

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = _s 'Error_dbatoolsNotFound'
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		$isRemote = ($SqlInstance -notlike "*$env:COMPUTERNAME*" -and $SqlInstance -ne 'localhost' -and $SqlInstance -ne '.')
		if ($isRemote -and -not $SearchPath)
		{
			Write-Warning (_s 'Orphaned_RemoteWarning')
		}

		Invoke-sqmLogging -Message (_s 'Orphaned_Starting' $functionName, $SqlInstance) -FunctionName $functionName -Level "INFO"
	}

	process
	{
		try
		{
			$connParams = @{ SqlInstance = $SqlInstance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

			$registeredSql = @"
SELECT
    DB_NAME(database_id) AS DatabaseName,
    name                 AS LogicalName,
    physical_name        AS PhysicalName,
    type_desc            AS FileType,
    size * 8 / 1024      AS SizeMB,
    state_desc           AS State
FROM sys.master_files
ORDER BY database_id, file_id
"@
			$registeredFiles = Invoke-DbaQuery @connParams -Database master -Query $registeredSql -ErrorAction Stop

			$registeredPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
			foreach ($f in $registeredFiles) { [void]$registeredPaths.Add($f.PhysicalName) }

			$dirsToSearch = [System.Collections.Generic.List[string]]::new()

			if ($SearchPath -and $SearchPath.Count -gt 0)
			{
				foreach ($p in $SearchPath) { $dirsToSearch.Add($p) }
			}
			else
			{
				$registeredFiles | ForEach-Object {
					$dir = [System.IO.Path]::GetDirectoryName($_.PhysicalName)
					if ($dir -and -not $dirsToSearch.Contains($dir)) { $dirsToSearch.Add($dir) }
				}

				$regSql = @"
DECLARE @DataDir NVARCHAR(512), @LogDir NVARCHAR(512);
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
    N'SOFTWARE\Microsoft\MSSQLServer\MSSQLServer', N'DefaultData', @DataDir OUTPUT;
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
    N'SOFTWARE\Microsoft\MSSQLServer\MSSQLServer', N'DefaultLog', @LogDir OUTPUT;
SELECT @DataDir AS DataDir, @LogDir AS LogDir;
"@
				$regResult = Invoke-DbaQuery @connParams -Database master -Query $regSql -ErrorAction SilentlyContinue
				if ($regResult)
				{
					if ($regResult.DataDir -and -not $dirsToSearch.Contains($regResult.DataDir)) { $dirsToSearch.Add($regResult.DataDir) }
					if ($regResult.LogDir  -and -not $dirsToSearch.Contains($regResult.LogDir))  { $dirsToSearch.Add($regResult.LogDir) }
				}
			}

			Invoke-sqmLogging -Message (_s 'Orphaned_DirectoriesCount' $dirsToSearch.Count) -FunctionName $functionName -Level "INFO"

			$orphaned = [System.Collections.Generic.List[PSCustomObject]]::new()
			$scanned  = 0

			foreach ($dir in $dirsToSearch)
			{
				if (-not (Test-Path $dir -ErrorAction SilentlyContinue))
				{
					Invoke-sqmLogging -Message (_s 'Orphaned_DirNotReachable' $dir) -FunctionName $functionName -Level "WARNING"
					continue
				}

				$getParams = @{ Path = $dir; ErrorAction = 'SilentlyContinue' }
				if ($Recurse) { $getParams['Recurse'] = $true }

				$files = Get-ChildItem @getParams | Where-Object {
					-not $_.PSIsContainer -and ($FileExtension -contains $_.Extension.ToLower())
				}

				foreach ($file in $files)
				{
					$scanned++
					if (-not $registeredPaths.Contains($file.FullName))
					{
						$orphaned.Add([PSCustomObject]@{
							FilePath     = $file.FullName
							FileName     = $file.Name
							Extension    = $file.Extension
							SizeMB       = [math]::Round($file.Length / 1MB, 2)
							LastModified = $file.LastWriteTime
							Directory    = $file.DirectoryName
							Status       = 'Orphaned'
						})
					}
				}
			}

			Invoke-sqmLogging -Message (_s 'Orphaned_Completed' $functionName, $scanned, $orphaned.Count) -FunctionName $functionName -Level "INFO"

			if ($orphaned.Count -eq 0)
			{
				Invoke-sqmLogging -Message (_s 'Orphaned_NoneFound') -FunctionName $functionName -Level "INFO"
			}

			return [PSCustomObject]@{
				SqlInstance     = $SqlInstance
				ScannedFiles    = $scanned
				RegisteredFiles = $registeredFiles.Count
				OrphanedFiles   = $orphaned.Count
				TotalOrphanedMB = [math]::Round(($orphaned | Measure-Object SizeMB -Sum).Sum, 2)
				Files           = $orphaned.ToArray()
			}
		}
		catch
		{
			$errMsg = _s 'Error_Generic' $functionName, $_.Exception.Message
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
		}
	}
}
