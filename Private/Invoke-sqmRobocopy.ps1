<#
.SYNOPSIS
    Ruft robocopy.exe auf und liefert Exitcode und Ausgabe zurueck.

.DESCRIPTION
    Duenner Wrapper, damit Unit-Tests den Kopiervorgang mocken koennen, ohne robocopy.exe zu starten.
    Wertet den Exitcode nicht aus - das macht der Aufrufer (robocopy meldet Erfolg mit Codes unter 8).
#>
function Invoke-sqmRobocopy
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string[]]$Arguments
	)

	$output = & robocopy.exe @Arguments 2>&1
	[PSCustomObject]@{
		ExitCode = $LASTEXITCODE
		Output   = @($output | ForEach-Object { [string]$_ })
	}
}
