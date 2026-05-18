<#
.SYNOPSIS
    Kopiert eine oder mehrere Dateien in den konfigurierten CentralPath.

.DESCRIPTION
    Wenn kein CentralPath konfiguriert ist, wird die Funktion ohne Fehler beendet.
    Nicht vorhandene Quelldateien werden uebersprungen.

.PARAMETER Path
    Pfad(e) der zu kopierenden Datei(en).
#>
function Copy-sqmToCentralPath
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string[]]$Path
	)
	
	$central = Get-sqmConfig -Key 'CentralPath'
	if (-not $central) { return }
	
	if (-not (Test-Path $central))
	{
		try
		{
			New-Item -ItemType Directory -Path $central -Force -ErrorAction Stop | Out-Null
		}
		catch
		{
			Write-Warning "CentralPath '$central' konnte nicht erstellt werden: $($_.Exception.Message)"
			return
		}
	}
	
	foreach ($file in $Path)
	{
		if (Test-Path $file)
		{
			$dest = Join-Path $central (Split-Path $file -Leaf)
			Copy-Item -Path $file -Destination $dest -Force -ErrorAction SilentlyContinue
			Write-Verbose "Datei '$file' nach '$dest' kopiert (CentralPath)."
		}
		else
		{
			Write-Verbose "Quelldatei '$file' nicht gefunden, wird uebersprungen."
		}
	}
}