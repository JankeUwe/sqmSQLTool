<#
.SYNOPSIS
    Gibt die aktuelle Modulkonfiguration zurueck.

.DESCRIPTION
    Ohne Parameter wird die gesamte Konfiguration als Hashtable zurueckgegeben.
    Mit -Key wird der Wert des angeforderten Schluessels geliefert.
    Existiert der Schluessel nicht, erscheint eine Warnung und es wird $null zurueckgegeben.

    HINWEIS: Die Initialisierung von $script:sqmModuleConfig erfolgt ausschliesslich
    in sqmSQLTool.psm1. Diese Datei enthaelt nur die Funktion Get-sqmConfig.

.PARAMETER Key
    Name des Konfigurationsschluessels (z. B. 'LogPath', 'OutputPath', 'CentralPath').

.EXAMPLE
    Get-sqmConfig

.EXAMPLE
    Get-sqmConfig -Key 'OutputPath'
#>
function Get-sqmConfig
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $false)]
		[string]$Key
	)
	if ($Key)
	{
		if ($script:sqmModuleConfig.ContainsKey($Key))
		{
			return $script:sqmModuleConfig[$Key]
		}
		else
		{
			Write-Warning "Konfigurationsschluessel '$Key' existiert nicht. Verfuegbare Schluessel: $($script:sqmModuleConfig.Keys -join ', ')"
			return $null
		}
	}
	return $script:sqmModuleConfig
}