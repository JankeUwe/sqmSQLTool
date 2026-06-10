<#
.SYNOPSIS
    Gibt einen lokalisierten String aus der aktiven Sprachdatei zurueck.

.DESCRIPTION
    Laedt beim ersten Aufruf die passende .psd1-Sprachdatei (de-DE oder en-US)
    basierend auf dem Config-Key 'Language' und cached das Ergebnis.
    Bei unbekanntem Key wird der Key-Name selbst zurueckgegeben (nie leer).
    Cache wird invalidiert wenn Set-sqmConfig -Language aufgerufen wird
    (setzt $script:_strings auf $null).

.PARAMETER Key
    String-Schluessel aus der Sprachdatei.

.PARAMETER FormatArgs
    Optionale Argumente fuer den -f Operator (Positionsargumente {0}, {1} ...).

.EXAMPLE
    Get-sqmString -Key 'Error_dbatoolsNotFound'

.EXAMPLE
    Get-sqmString -Key 'Failover_RedoQueueLimit' -FormatArgs 'SQL02', 55, 50
#>
function Get-sqmString
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Key,
        [Parameter(Mandatory = $false, Position = 1)]
        [object[]]$FormatArgs
    )

    # Cache einmalig laden
    if (-not $script:_strings)
    {
        $lang = $null
        if ($script:sqmModuleConfig) { $lang = $script:sqmModuleConfig['Language'] }
        if (-not $lang) { $lang = 'en-US' }

        $strFile = Join-Path $PSScriptRoot "Strings\$lang.psd1"
        if (-not (Test-Path $strFile))
        {
            $strFile = Join-Path $PSScriptRoot 'Strings\de-DE.psd1'
        }

        try
        {
            $script:_strings = Import-PowerShellDataFile -Path $strFile -ErrorAction Stop
        }
        catch
        {
            # Fallback: leere Hashtable - Key wird direkt zurueckgegeben
            $script:_strings = @{}
        }
    }

    $template = $script:_strings[$Key]
    if (-not $template) { return $Key }          # Key als Fallback - nie leer
    if ($FormatArgs -and $FormatArgs.Count -gt 0) { return ($template -f $FormatArgs) }
    return $template
}

# Kurzalias fuer sauberen Code in Funktionen
# Aufruf: _s 'Key'  oder  _s 'Key' $arg1, $arg2, $arg3
function _s
{
    param(
        [Parameter(Position = 0)][string]$Key,
        [Parameter(Position = 1)][object[]]$FormatArgs
    )
    Get-sqmString -Key $Key -FormatArgs $FormatArgs
}
