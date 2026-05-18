<#
.SYNOPSIS
    Copies one or more files to the configured CentralPath.

.DESCRIPTION
    If no CentralPath is configured, the function exits without error.
    Source files that do not exist are skipped.

.PARAMETER Path
    Path(s) of the file(s) to copy.
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