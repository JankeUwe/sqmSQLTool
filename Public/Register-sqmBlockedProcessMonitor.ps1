<#
.SYNOPSIS
    Creates (if missing) and starts a dedicated Extended Events session that captures
    blocked_process_report and xml_deadlock_report events.

.DESCRIPTION
    The built-in system_health session does NOT reliably include blocked_process_report on
    every instance/version - verified live: on a default installation the event is simply
    absent from system_health's definition, so blocked_process_report events fire (once
    'blocked process threshold (s)' > 0) but are captured nowhere at all. Get-sqmBlockingHistory
    depends on this function to guarantee a capture target exists, independent of whatever
    system_health happens to contain on a given instance.

    Session name: sqm_BlockedProcessMonitor
    Events: sqlserver.blocked_process_report, sqlserver.xml_deadlock_report
    Target: package0.ring_buffer (in-memory, ~4 MB, wraps around) by default.
    With -IncludeFileTarget, an additional package0.event_file target is added for longer
    retention (50 MB, 5 rollover files) under the instance's own error log directory
    (resolved via SERVERPROPERTY('ErrorLogFileName') - guaranteed writable by the SQL
    Server service account) unless -FileTargetPath is given explicitly.

    STARTUP_STATE=ON is set, so the session survives an instance restart. If the session
    already exists, this function only ensures it is currently running (STATE=START) -
    it never drops/recreates an existing session, so a file target added once is preserved.

    This function only creates/starts the monitoring session. It does NOT change
    'blocked process threshold (s)' itself (0 = disabled by default) - see
    Get-sqmBlockingHistory's warning when the threshold is 0.

.PARAMETER SqlInstance
    SQL Server instance. Default: $env:COMPUTERNAME.

.PARAMETER SqlCredential
    PSCredential for SQL authentication. Default: Windows auth.

.PARAMETER IncludeFileTarget
    Also adds a package0.event_file target for retention beyond the ring buffer's limited
    in-memory window. Only takes effect when the session is first created.

.PARAMETER FileTargetPath
    Directory for the event_file target (only used with -IncludeFileTarget). Default: the
    instance's own error log directory.

.PARAMETER EnableException
    Throw exceptions immediately instead of returning as errors.

.OUTPUTS
    PSCustomObject: SqlInstance, SessionName, Action, Message

.EXAMPLE
    Register-sqmBlockedProcessMonitor -SqlInstance "SQL01"

.EXAMPLE
    Register-sqmBlockedProcessMonitor -SqlInstance "SQL01" -IncludeFileTarget

.EXAMPLE
    Register-sqmBlockedProcessMonitor -SqlInstance "SQL01" -WhatIf

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    Permissions: ALTER ANY EVENT SESSION (sysadmin covers this).
    Does not set 'blocked process threshold (s)' - that remains a deliberate, separate
    admin decision (it is a server-wide advanced option).
#>
function Register-sqmBlockedProcessMonitor
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeFileTarget,
		[Parameter(Mandatory = $false)]
		[string]$FileTargetPath,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$sessionName = 'sqm_BlockedProcessMonitor'

		if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
		{
			$SqlInstance = $env:COMPUTERNAME
		}

		if (-not $script:dbatoolsAvailable)
		{
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}
	}

	process
	{
		try
		{
			$connParams = @{ SqlInstance = $SqlInstance }
			if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

			$existingSession = Invoke-DbaQuery @connParams -Database master `
				-Query "SELECT 1 AS Found FROM sys.server_event_sessions WHERE name = N'$sessionName'" -ErrorAction Stop

			if (-not $existingSession)
			{
				$targetSql = "ADD TARGET package0.ring_buffer(SET max_memory=4096)"
				if ($IncludeFileTarget)
				{
					$fileDir = $FileTargetPath
					if (-not $fileDir)
					{
						$dirRow = Invoke-DbaQuery @connParams -Database master -Query @"
DECLARE @ErrLog NVARCHAR(260) = CAST(SERVERPROPERTY('ErrorLogFileName') AS NVARCHAR(260));
SELECT LEFT(@ErrLog, LEN(@ErrLog) - CHARINDEX('\', REVERSE(@ErrLog))) AS ErrorLogDir;
"@
						$fileDir = if ($dirRow) { $dirRow.ErrorLogDir } else { $null }
					}
					if ($fileDir)
					{
						$fileDirSql = $fileDir.Replace("'", "''")
						$targetSql += ",`nADD TARGET package0.event_file(SET filename=N'$fileDirSql\sqm_BlockedProcessMonitor.xel', max_file_size=50, max_rollover_files=5)"
					}
					else
					{
						Invoke-sqmLogging -Message "[$SqlInstance] Konnte ErrorLog-Verzeichnis fuer den File-Target nicht ermitteln - nur Ring-Buffer wird angelegt." -FunctionName $functionName -Level "WARNING"
					}
				}

				$createSql = @"
CREATE EVENT SESSION [$sessionName] ON SERVER
ADD EVENT sqlserver.blocked_process_report,
ADD EVENT sqlserver.xml_deadlock_report
$targetSql
WITH (MAX_MEMORY=4096KB, EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS, MAX_DISPATCH_LATENCY=5 SECONDS, STARTUP_STATE=ON)
"@
				$actionMsg = "Lege Extended-Events-Session '$sessionName' an"
				if ($PSCmdlet.ShouldProcess($SqlInstance, $actionMsg))
				{
					Invoke-DbaQuery @connParams -Database master -Query $createSql -ErrorAction Stop
					Invoke-DbaQuery @connParams -Database master -Query "ALTER EVENT SESSION [$sessionName] ON SERVER STATE = START;" -ErrorAction Stop
					Invoke-sqmLogging -Message "[$SqlInstance] Session '$sessionName' angelegt und gestartet." -FunctionName $functionName -Level "INFO"
					return [PSCustomObject]@{
						SqlInstance = $SqlInstance
						SessionName = $sessionName
						Action	    = 'Created'
						Message	    = "Session '$sessionName' wurde neu angelegt und gestartet."
					}
				}
				else
				{
					return [PSCustomObject]@{
						SqlInstance = $SqlInstance
						SessionName = $sessionName
						Action	    = 'WhatIfSkipped'
						Message	    = "WhatIf: Session '$sessionName' wuerde angelegt werden."
					}
				}
			}
			else
			{
				$isRunning = Invoke-DbaQuery @connParams -Database master `
					-Query "SELECT 1 AS Running FROM sys.dm_xe_sessions WHERE name = N'$sessionName'" -ErrorAction Stop

				if (-not $isRunning)
				{
					$actionMsg = "Starte vorhandene, aber gestoppte Session '$sessionName'"
					if ($PSCmdlet.ShouldProcess($SqlInstance, $actionMsg))
					{
						Invoke-DbaQuery @connParams -Database master -Query "ALTER EVENT SESSION [$sessionName] ON SERVER STATE = START;" -ErrorAction Stop
						Invoke-sqmLogging -Message "[$SqlInstance] Session '$sessionName' war gestoppt und wurde gestartet." -FunctionName $functionName -Level "INFO"
						return [PSCustomObject]@{
							SqlInstance = $SqlInstance
							SessionName = $sessionName
							Action	    = 'Started'
							Message	    = "Session '$sessionName' existierte bereits, war aber gestoppt - jetzt gestartet."
						}
					}
					else
					{
						return [PSCustomObject]@{
							SqlInstance = $SqlInstance
							SessionName = $sessionName
							Action	    = 'WhatIfSkipped'
							Message	    = "WhatIf: Session '$sessionName' wuerde gestartet werden."
						}
					}
				}

				return [PSCustomObject]@{
					SqlInstance = $SqlInstance
					SessionName = $sessionName
					Action	    = 'Unchanged'
					Message	    = "Session '$sessionName' existiert bereits und laeuft."
				}
			}
		}
		catch
		{
			$errMsg = "Fehler beim Anlegen/Starten von '$sessionName': $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
			return $null
		}
	}
}
