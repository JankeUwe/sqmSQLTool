<#
.SYNOPSIS
    Returns the current module configuration.

.DESCRIPTION
    Without parameters, the entire configuration is returned as a hashtable.
    With -Key, the value of the requested key is returned.
    If the key does not exist, a warning is shown and $null is returned.

    NOTE: Initialization of $script:sqmModuleConfig is performed exclusively
    in sqmSQLTool.psm1. This file contains only the Get-sqmConfig function.

.PARAMETER Key
    Name of the configuration key (e.g. 'LogPath', 'OutputPath', 'CentralPath').

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