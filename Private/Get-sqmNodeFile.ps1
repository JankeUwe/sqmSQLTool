<#
.SYNOPSIS
    Listet die Dateien eines Verzeichnisses (lokal oder Admin-Freigabe eines Knotens) nach Platzhalter.

.DESCRIPTION
    Liefert nichts, wenn das Verzeichnis nicht existiert. Duenner Wrapper, damit Unit-Tests den Zugriff auf den
    zweiten Knoten mocken koennen, ohne Test-Path und Get-ChildItem selbst zu ueberschreiben.
#>
function Get-sqmNodeFile
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]$Directory,

		[Parameter(Mandatory = $true)]
		[string]$Filter
	)

	if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
	Get-ChildItem -LiteralPath $Directory -Filter $Filter -File -ErrorAction Stop
}
