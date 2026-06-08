<#
.SYNOPSIS
    Executes numbered SQL scripts from a directory sequentially against a SQL Server database.

.DESCRIPTION
    Runs all SQL script files whose filename starts with a numeric prefix (e.g. 001_CreateTable.sql)
    in ascending numeric order against the specified database. Before execution the function:

    - Validates that ScriptPath and LogPath exist (LogPath is created if missing)
    - Optionally creates a full database backup in a Sonderbackup subdirectory
    - Scans every script for USE DATABASE mismatches and nested BEGIN TRANSACTION statements
    - Wraps all scripts in one outer transaction by default (COMMIT on full success, ROLLBACK on any error)
    - Writes a detailed .log and .csv file to LogPath
    - Returns a result object per script plus an overall summary object

    When -WhatIf is specified the function performs all pre-checks and prints a summary table
    but does not execute any SQL or create any files.

.PARAMETER SqlInstance
    SQL Server instance name (e.g. "SQLSERVER01" or "SQLSERVER01\INST1").

.PARAMETER Database
    Target database name.

.PARAMETER ScriptPath
    Directory that contains the numbered SQL script files.

.PARAMETER LogPath
    Directory where the .log and .csv output files are written. Created if it does not exist.

.PARAMETER JobNumber
    Optional job or order number. When provided it is embedded in the log filename:
    yyyyMMdd_HHmmss_{JobNumber}_Deploy.log / .csv

.PARAMETER QueryTimeout
    Timeout in seconds per script execution. Default: 30.

.PARAMETER SkipBackup
    Skip the pre-deployment backup. Requires ShouldProcess confirmation (ConfirmImpact=High).
    If the user declines the confirmation the function aborts.
    When -SkipBackup is NOT set and the backup fails the function aborts before running any scripts.

.PARAMETER NoWrapTransaction
    Do not wrap all scripts in one outer transaction. Each script is responsible for its own
    transaction management. Default behavior: all scripts run inside one BEGIN/COMMIT/ROLLBACK block.

.PARAMETER SqlCredential
    PSCredential for SQL Server authentication. When omitted Windows Authentication is used.

.EXAMPLE
    # Basic deploy with automatic backup
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy"

.EXAMPLE
    # Deploy with job number embedded in log filename
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy" -JobNumber "AU-2026-042"

.EXAMPLE
    # Skip backup - requires interactive confirmation
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy" -SkipBackup

.EXAMPLE
    # WhatIf dry run - no SQL executed, only pre-checks and summary table
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy" -WhatIf

.EXAMPLE
    # No outer transaction - scripts manage their own transactions
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy" -NoWrapTransaction

.EXAMPLE
    # SQL Server authentication
    $cred = Get-Credential
    Invoke-sqmDeployScripts -SqlInstance "SQLSERVER01" -Database "SalesDB" `
        -ScriptPath "D:\Deploy\v2.3" -LogPath "D:\Logs\Deploy" -SqlCredential $cred

.NOTES
    Author:       sqmSQLTool
    Prerequisites: dbatools, Invoke-sqmLogging
    Script discovery pattern: filename must begin with one or more digits (^\d+), extension .sql
    Sort order: ascending by the parsed numeric prefix
#>
function Invoke-sqmDeployScripts
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $true, Position = 1)]
		[string]$Database,

		[Parameter(Mandatory = $true)]
		[string]$ScriptPath,

		[Parameter(Mandatory = $true)]
		[string]$LogPath,

		[Parameter(Mandatory = $false)]
		[string]$JobNumber,

		[Parameter(Mandatory = $false)]
		[int]$QueryTimeout = 30,

		[Parameter(Mandatory = $false)]
		[switch]$SkipBackup,

		[Parameter(Mandatory = $false)]
		[switch]$NoWrapTransaction,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$startTime    = Get-Date
		$results      = [System.Collections.Generic.List[PSCustomObject]]::new()
		$logLines     = [System.Collections.Generic.List[string]]::new()

		# ----------------------------------------------------------------
		# Helper: write to console AND accumulate in $logLines
		# ----------------------------------------------------------------
		function _Log
		{
			param (
				[string]$Msg,
				[string]$Level = 'INFO',
				[switch]$NoConsole
			)
			$ts   = Get-Date -Format 'HH:mm:ss'
			$line = "[$ts] $($Level.PadRight(7)) $Msg"
			$logLines.Add($line)
			if (-not $NoConsole)
			{
				switch ($Level)
				{
					'ERROR'   { Write-Host $line -ForegroundColor Red }
					'WARNING' { Write-Host $line -ForegroundColor Yellow }
					default   { Write-Host $line }
				}
			}
			Invoke-sqmLogging -Message $Msg -FunctionName $functionName -Level $Level
		}

		# ----------------------------------------------------------------
		# Validate ScriptPath
		# ----------------------------------------------------------------
		if (-not (Test-Path -Path $ScriptPath -PathType Container))
		{
			$msg = "ScriptPath not found: $ScriptPath"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
			throw $msg
		}

		# ----------------------------------------------------------------
		# Ensure LogPath exists
		# ----------------------------------------------------------------
		if (-not (Test-Path -Path $LogPath -PathType Container))
		{
			New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
			Invoke-sqmLogging -Message "LogPath created: $LogPath" -FunctionName $functionName -Level 'INFO'
		}

		# ----------------------------------------------------------------
		# Build log filenames
		# ----------------------------------------------------------------
		$fileStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
		if ($JobNumber)
		{
			$logFile = Join-Path $LogPath "${fileStamp}_${JobNumber}_Deploy.log"
			$csvFile = Join-Path $LogPath "${fileStamp}_${JobNumber}_Deploy.csv"
		}
		else
		{
			$logFile = Join-Path $LogPath "${fileStamp}_Deploy.log"
			$csvFile = Join-Path $LogPath "${fileStamp}_Deploy.csv"
		}

		# ----------------------------------------------------------------
		# Script discovery - files matching ^\d+.*\.sql$
		# ----------------------------------------------------------------
		$allFiles     = Get-ChildItem -Path $ScriptPath -File -Filter '*.sql'
		$sortedScripts = [System.Collections.Generic.List[PSCustomObject]]::new()
		$skippedFiles  = [System.Collections.Generic.List[string]]::new()

		foreach ($file in $allFiles)
		{
			if ($file.Name -match '^(\d+)')
			{
				$numericPrefix = [int]$Matches[1]
				$sortedScripts.Add([PSCustomObject]@{
					File          = $file
					NumericPrefix = $numericPrefix
				})
			}
			else
			{
				$skippedFiles.Add($file.Name)
			}
		}

		# Sort ascending by numeric prefix
		$sortedScripts = @($sortedScripts | Sort-Object -Property NumericPrefix)

		# ----------------------------------------------------------------
		# Build log header (accumulate; will be written to file later)
		# ----------------------------------------------------------------
		$separator = '=' * 60
		$logLines.Add($separator)
		$logLines.Add('  sqmSQLTool - Database Deployment')
		$logLines.Add("  Date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
		$logLines.Add("  Instance : $SqlInstance")
		$logLines.Add("  Database : $Database")
		$logLines.Add("  Scripts  : $ScriptPath")
		if ($JobNumber) { $logLines.Add("  Job Nr   : $JobNumber") }
		$logLines.Add($separator)
		$logLines.Add('')

		# Echo header to console
		foreach ($line in $logLines) { Write-Host $line }

		# ----------------------------------------------------------------
		# Log discovered scripts
		# ----------------------------------------------------------------
		_Log "Discovered $($sortedScripts.Count) script(s) to execute"
		foreach ($s in $sortedScripts)
		{
			_Log "  $($s.File.Name)"
		}

		foreach ($skipped in $skippedFiles)
		{
			_Log "Skipped (no numeric prefix): $skipped" -Level 'WARNING'
			$results.Add([PSCustomObject]@{
				ScriptName     = $skipped
				NumericPrefix  = $null
				Status         = 'Skipped'
				DurationSeconds = 0
				ErrorMessage   = 'Filename does not start with digits'
				ExecutedAt     = $null
			})
		}

		# ----------------------------------------------------------------
		# Pre-checks: USE DATABASE mismatch and nested BEGIN TRANSACTION
		# ----------------------------------------------------------------
		$useMismatches   = [System.Collections.Generic.List[PSCustomObject]]::new()
		$nestedTranFiles = [System.Collections.Generic.List[string]]::new()

		foreach ($s in $sortedScripts)
		{
			$content = Get-Content -Path $s.File.FullName -Raw -Encoding UTF8

			# Check 1: USE DATABASE
			$useMatches = [regex]::Matches($content, '(?im)^\s*USE\s+[\[\"]?(\w+)[\]\"]?\s*')
			foreach ($m in $useMatches)
			{
				$usedDb = $m.Groups[1].Value
				if ($usedDb -ne $Database)
				{
					$useMismatches.Add([PSCustomObject]@{
						ScriptName = $s.File.Name
						UsedDb     = $usedDb
					})
				}
			}

			# Check 2: BEGIN TRANSACTION inside scripts (only relevant when wrapping)
			if (-not $NoWrapTransaction)
			{
				if ($content -match '(?i)\bBEGIN\s+(TRAN|TRANSACTION)\b')
				{
					$nestedTranFiles.Add($s.File.Name)
				}
			}
		}

		# Report USE mismatches
		if ($useMismatches.Count -gt 0)
		{
			_Log "USE DATABASE mismatch found in $($useMismatches.Count) script(s):" -Level 'WARNING'
			foreach ($m in $useMismatches)
			{
				_Log "  $($m.ScriptName) -> USE [$($m.UsedDb)]" -Level 'WARNING'
			}

			if ($WhatIfPreference -or $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('WhatIf'))
			{
				_Log "WhatIf mode: USE DATABASE mismatch logged, not prompting." -Level 'WARNING'
			}
			else
			{
				Write-Host ''
				Write-Host "WARNING: $($useMismatches.Count) script(s) contain USE [database] pointing to a different database." -ForegroundColor Yellow
				foreach ($m in $useMismatches)
				{
					Write-Host "  $($m.ScriptName) -> USE [$($m.UsedDb)]" -ForegroundColor Yellow
				}
				$answer = Read-Host 'Continue anyway? [Y/N]'
				if ($answer -notmatch '^[Yy]$')
				{
					$abortMsg = 'Aborted by user due to USE DATABASE mismatch'
					_Log $abortMsg -Level 'ERROR'
					throw $abortMsg
				}
			}
		}

		# Report nested BEGIN TRANSACTION
		if ($nestedTranFiles.Count -gt 0)
		{
			_Log "Scripts with nested BEGIN TRANSACTION (dangerous with -WrapTransaction mode): $($nestedTranFiles.Count)" -Level 'WARNING'
			foreach ($f in $nestedTranFiles)
			{
				_Log "  $f" -Level 'WARNING'
			}

			if ($WhatIfPreference -or $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('WhatIf'))
			{
				_Log "WhatIf mode: nested TRANSACTION warning logged, not prompting." -Level 'WARNING'
			}
			else
			{
				Write-Host ''
				Write-Host "WARNING: $($nestedTranFiles.Count) script(s) contain BEGIN TRANSACTION - nested transactions are dangerous with -WrapTransaction mode." -ForegroundColor Yellow
				$answer = Read-Host 'Continue with -WrapTransaction despite nested transactions? [Y/N]'
				if ($answer -notmatch '^[Yy]$')
				{
					$abortMsg = 'Aborted by user due to nested transactions in wrap-transaction mode'
					_Log $abortMsg -Level 'ERROR'
					throw $abortMsg
				}
			}
		}

		# ----------------------------------------------------------------
		# WhatIf: print summary table and return
		# ----------------------------------------------------------------
		if ($WhatIfPreference)
		{
			Write-Host ''
			Write-Host 'WhatIf - Deployment Pre-Check Summary' -ForegroundColor Cyan
			Write-Host ('-' * 70)
			$fmt = '{0,-6}  {1,-40}  {2,-12}  {3}'
			Write-Host ($fmt -f 'Order', 'Script', 'USE-DB Check', 'TRAN Check')
			Write-Host ('-' * 70)
			foreach ($s in $sortedScripts)
			{
				$useStatus  = if (($useMismatches | Where-Object ScriptName -eq $s.File.Name).Count -gt 0) { 'MISMATCH' } else { 'OK' }
				$tranStatus = if ($nestedTranFiles -contains $s.File.Name) { 'NESTED' } else { 'OK' }
				Write-Host ($fmt -f $s.NumericPrefix, $s.File.Name, $useStatus, $tranStatus)
			}
			Write-Host ('-' * 70)
			Write-Host "Total scripts: $($sortedScripts.Count)  |  USE mismatches: $($useMismatches.Count)  |  Nested TRANs: $($nestedTranFiles.Count)"
			Write-Host ''
			_Log "WhatIf: pre-checks completed, no scripts executed."
			return
		}
	}

	process
	{
		$backupFile = $null

		# ----------------------------------------------------------------
		# Connect to SQL Server
		# ----------------------------------------------------------------
		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		try
		{
			$server = Connect-DbaInstance @connParams -EnableException
		}
		catch
		{
			$msg = "Failed to connect to '$SqlInstance': $($_.Exception.Message)"
			_Log $msg -Level 'ERROR'
			throw $msg
		}

		# ----------------------------------------------------------------
		# Backup logic
		# ----------------------------------------------------------------
		if ($SkipBackup)
		{
			$shouldMsg = "Skipping backup for database '$Database' on '$SqlInstance'. Data loss risk if scripts fail."
			if (-not $PSCmdlet.ShouldProcess($Database, $shouldMsg))
			{
				$abortMsg = "Deployment aborted - user declined to skip backup without confirmation."
				_Log $abortMsg -Level 'ERROR'
				throw $abortMsg
			}
			_Log "Backup skipped by user request (-SkipBackup)." -Level 'WARNING'
		}
		else
		{
			_Log "Starting pre-deployment backup of '$Database' on '$SqlInstance'..."

			try
			{
				$defaultBackupPath = (Get-DbaDefaultPath -SqlInstance $server).Backup

				# If path ends with database name, go one level up
				if ($defaultBackupPath.TrimEnd('\\/').EndsWith($Database, [System.StringComparison]::OrdinalIgnoreCase))
				{
					$defaultBackupPath = Split-Path $defaultBackupPath.TrimEnd('\\/') -Parent
				}

				$backupDir = Join-Path $defaultBackupPath 'Sonderbackup'
				if (-not (Test-Path $backupDir))
				{
					New-Item -ItemType Directory -Path $backupDir | Out-Null
					_Log "Created backup directory: $backupDir"
				}

				$backupResult = Backup-DbaDatabase -SqlInstance $server -Database $Database `
					-Path $backupDir -BackupFileName '{database}_{timestamp}.bak' `
					-CompressBackup -EnableException:$false

				if (-not $backupResult -or $backupResult.BackupComplete -ne $true)
				{
					_Log "Backup failed or did not complete successfully - deployment aborted." -Level 'ERROR'
					Write-Error "Backup failed - deployment aborted"
					return
				}

				$backupFile = $backupResult.BackupPath
				if (-not $backupFile) { $backupFile = $backupResult.BackupFile }

				# Append backup info to header section of log
				$headerBackupLine = "  Backup   : $backupFile"
				$logLines.Insert($logLines.Count - 1, $headerBackupLine)
				_Log "Backup completed: $backupFile"
			}
			catch
			{
				_Log "Backup exception: $($_.Exception.Message) - deployment aborted." -Level 'ERROR'
				Write-Error "Backup failed - deployment aborted: $($_.Exception.Message)"
				return
			}
		}

		# ----------------------------------------------------------------
		# Script execution
		# ----------------------------------------------------------------
		$transactionActive = $false
		$queryParams = @{
			SqlInstance   = $server
			Database      = $Database
			QueryTimeout  = $QueryTimeout
			EnableException = $true
		}

		if (-not $NoWrapTransaction)
		{
			try
			{
				Invoke-DbaQuery @queryParams -Query 'BEGIN TRANSACTION' | Out-Null
				$transactionActive = $true
				_Log 'BEGIN TRANSACTION (wrapper)'
			}
			catch
			{
				_Log "Failed to start wrapper transaction: $($_.Exception.Message)" -Level 'ERROR'
				throw
			}
		}

		$anyFailed    = $false
		$notExecuted  = 0

		foreach ($s in $sortedScripts)
		{
			if ($anyFailed)
			{
				$notExecuted++
				$results.Add([PSCustomObject]@{
					ScriptName      = $s.File.Name
					NumericPrefix   = $s.NumericPrefix
					Status          = 'NotExecuted'
					DurationSeconds = 0
					ErrorMessage    = 'Previous script failed'
					ExecutedAt      = $null
				})
				continue
			}

			$scriptContent = Get-Content -Path $s.File.FullName -Raw -Encoding UTF8
			$scriptStart   = Get-Date

			try
			{
				Invoke-DbaQuery @queryParams -Query $scriptContent -MessagesToOutput | Out-Null
				$duration = ((Get-Date) - $scriptStart).TotalSeconds
				$durStr   = [math]::Round($duration, 1)

				_Log "[OK]  $($s.File.Name)  (${durStr}s)"

				$results.Add([PSCustomObject]@{
					ScriptName      = $s.File.Name
					NumericPrefix   = $s.NumericPrefix
					Status          = 'Success'
					DurationSeconds = $durStr
					ErrorMessage    = ''
					ExecutedAt      = $scriptStart
				})
			}
			catch
			{
				$duration  = ((Get-Date) - $scriptStart).TotalSeconds
				$durStr    = [math]::Round($duration, 1)
				$errMsg    = $_.Exception.Message
				$anyFailed = $true

				_Log "[FAIL] $($s.File.Name)  (${durStr}s)" -Level 'ERROR'
				_Log "       Error: $errMsg" -Level 'ERROR'

				$results.Add([PSCustomObject]@{
					ScriptName      = $s.File.Name
					NumericPrefix   = $s.NumericPrefix
					Status          = 'Failed'
					DurationSeconds = $durStr
					ErrorMessage    = $errMsg
					ExecutedAt      = $scriptStart
				})

				if (-not $NoWrapTransaction -and $transactionActive)
				{
					try
					{
						Invoke-DbaQuery @queryParams -Query 'ROLLBACK TRANSACTION' | Out-Null
						$transactionActive = $false
						_Log 'ROLLBACK TRANSACTION' -Level 'ERROR'
					}
					catch
					{
						_Log "Failed to rollback transaction: $($_.Exception.Message)" -Level 'ERROR'
					}
				}
			}
		}

		if (-not $NoWrapTransaction -and $transactionActive)
		{
			try
			{
				Invoke-DbaQuery @queryParams -Query 'COMMIT TRANSACTION' | Out-Null
				_Log 'COMMIT TRANSACTION'
			}
			catch
			{
				_Log "Failed to commit transaction: $($_.Exception.Message)" -Level 'ERROR'
				try
				{
					Invoke-DbaQuery @queryParams -Query 'ROLLBACK TRANSACTION' | Out-Null
					_Log 'ROLLBACK TRANSACTION (commit failed)' -Level 'ERROR'
				}
				catch { }
				$anyFailed = $true
			}
		}

		# ----------------------------------------------------------------
		# Compute summary stats
		# ----------------------------------------------------------------
		$scriptResults = $results | Where-Object { $_.Status -ne 'Skipped' }
		$succeeded     = @($scriptResults | Where-Object Status -eq 'Success').Count
		$failed        = @($scriptResults | Where-Object Status -eq 'Failed').Count
		$notExecCount  = @($scriptResults | Where-Object Status -eq 'NotExecuted').Count
		$skippedCount  = @($results | Where-Object Status -eq 'Skipped').Count
		$overallStatus = if ($anyFailed) { 'FAILED' } else { 'SUCCESS' }
		$totalDuration = ((Get-Date) - $startTime).TotalSeconds
		$totalDurStr   = [math]::Round($totalDuration, 0)
		$totalDurTS    = [TimeSpan]::FromSeconds($totalDuration).ToString('hh\:mm\:ss')

		# ----------------------------------------------------------------
		# Final log section
		# ----------------------------------------------------------------
		_Log ''
		_Log $separator
		$statusLine = "  RESULT  : $overallStatus  ($succeeded succeeded, $failed failed, $notExecCount not executed)"
		_Log $statusLine
		_Log "  Duration: $totalDurTS"
		_Log $separator
	}

	end
	{
		# ----------------------------------------------------------------
		# Write log file
		# ----------------------------------------------------------------
		try
		{
			$logLines | Out-File -FilePath $logFile -Encoding UTF8 -Force
			_Log "Log written: $logFile" -NoConsole
		}
		catch
		{
			Write-Warning "Could not write log file '$logFile': $($_.Exception.Message)"
		}

		# ----------------------------------------------------------------
		# Write CSV file (skip if WhatIf)
		# ----------------------------------------------------------------
		if (-not $WhatIfPreference -and $results.Count -gt 0)
		{
			try
			{
				$results | Select-Object ScriptName, NumericPrefix, Status, DurationSeconds, ErrorMessage, ExecutedAt |
					Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force
			}
			catch
			{
				Write-Warning "Could not write CSV file '$csvFile': $($_.Exception.Message)"
			}
		}

		# ----------------------------------------------------------------
		# Build summary object
		# ----------------------------------------------------------------
		$overallStatus2 = if (($results | Where-Object Status -eq 'Failed').Count -gt 0) { 'FAILED' } else { 'SUCCESS' }

		$summaryObj = [PSCustomObject]@{
			OverallStatus        = $overallStatus2
			TotalScripts         = $sortedScripts.Count
			Succeeded            = @($results | Where-Object Status -eq 'Success').Count
			Failed               = @($results | Where-Object Status -eq 'Failed').Count
			Skipped              = @($results | Where-Object Status -eq 'Skipped').Count
			NotExecuted          = @($results | Where-Object Status -eq 'NotExecuted').Count
			BackupFile           = $backupFile
			LogFile              = $logFile
			CsvFile              = $csvFile
			TotalDurationSeconds = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
		}

		# ----------------------------------------------------------------
		# Copy summary table to clipboard
		# ----------------------------------------------------------------
		try
		{
			$clipText = $results |
				Select-Object ScriptName, NumericPrefix, Status, DurationSeconds, ErrorMessage |
				Format-Table -AutoSize |
				Out-String
			$clipText += "`r`nOverall: $($summaryObj.OverallStatus) | Succeeded: $($summaryObj.Succeeded) | Failed: $($summaryObj.Failed) | Duration: $($summaryObj.TotalDurationSeconds)s"
			$clipText | clip.exe
		}
		catch
		{
			Write-Verbose "Could not copy summary to clipboard: $($_.Exception.Message)"
		}

		# ----------------------------------------------------------------
		# Return results
		# ----------------------------------------------------------------
		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		foreach ($r in $results) { $allResults.Add($r) }
		$allResults.Add($summaryObj)
		return $allResults
	}
}
