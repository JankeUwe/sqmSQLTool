<#
.SYNOPSIS
    Prueft, ob ein Pfad (z. B. die Admin-Freigabe eines Knotens) erreichbar ist.

.DESCRIPTION
    Duenner Wrapper um Test-Path, damit Unit-Tests die Erreichbarkeit eines zweiten Knotens steuern koennen.
#>
function Test-sqmPathReachable
{
	[CmdletBinding()]
	[OutputType([bool])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	[bool](Test-Path -LiteralPath $Path)
}
