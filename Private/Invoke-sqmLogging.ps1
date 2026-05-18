<#
.SYNOPSIS
    Schreibt eine Lognachricht in die tagesaktuelle Logdatei der Funktion.

.DESCRIPTION
    Erstellt pro Tag und aufrufender Funktion eine eigene Logdatei im konfigurierten LogPath.
    Schreibt nur, wenn $script:sqmLoggingReady = $true (wird beim Modulimport gesetzt).

.PARAMETER Message
    Der zu protokollierende Text.

.PARAMETER FunctionName
    Name der aufrufenden Funktion (wird im Dateinamen verwendet).

.PARAMETER Level
    Log-Level: INFO, WARNING, ERROR, DEBUG, VERBOSE. Standard: INFO.
#>
function Invoke-sqmLogging
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]$Message,
		[Parameter(Mandatory = $false)]
		[string]$FunctionName = 'General',
		[Parameter(Mandatory = $false)]
		[ValidateSet('INFO', 'WARNING', 'ERROR', 'DEBUG', 'VERBOSE')]
		[string]$Level = 'INFO'
	)
	
	# KORREKTUR #7: $script: statt $Global:
	$logPath = Get-sqmConfig -Key "LogPath"
	
	if ($script:sqmLoggingReady -and $logPath)
	{
		$dateStamp = Get-Date -Format "yyyyMMdd"
		$fileName = "sqmSQLTool_$($dateStamp)_$($FunctionName).log"
		$fullPath = Join-Path $logPath $fileName
		
		$timestamp = Get-Date -Format "HH:mm:ss"
		"[$timestamp] [$Level] $Message" | Out-File -FilePath $fullPath -Append -Encoding UTF8
	}
}