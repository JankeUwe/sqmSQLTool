<#
.SYNOPSIS
    Checks if a newer version of sqmSQLTool is available on PowerShell Gallery.

.DESCRIPTION
    Queries PowerShell Gallery for the latest published version of sqmSQLTool
    and compares it with the locally installed version.

.PARAMETER ModuleName
    Module name to check. Default: sqmSQLTool

.PARAMETER EnableException
    Throw exceptions immediately instead of returning error object.

.EXAMPLE
    Test-sqmUpdateViaPSGallery

.EXAMPLE
    $result = Test-sqmUpdateViaPSGallery
    if ($result.UpdateAvailable) { Update-sqmModule -Source PSGallery }

.NOTES
    Requires internet access to www.powershellgallery.com
#>
function Test-sqmUpdateViaPSGallery
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false)]
        [string]$ModuleName = 'sqmSQLTool',
        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    $functionName = $MyInvocation.MyCommand.Name
    Invoke-sqmLogging -Message "Starte $functionName - Pruefe PSGallery auf neue Version" -FunctionName $functionName -Level "INFO"

    try
    {
        # Lokale Version
        $localModule = Get-Module -Name $ModuleName -ErrorAction SilentlyContinue
        if (-not $localModule)
        {
            $localModule = Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        $localVersion = if ($localModule) { [version]$localModule.Version } else { [version]'0.0.0.0' }

        # PSGallery API abfragen
        $apiUrl = "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='$ModuleName'&`$top=1&`$orderby=Version+desc&`$filter=IsLatestVersion"
        $response = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop

        if (-not $response -or -not $response.properties)
        {
            throw "Modul '$ModuleName' nicht auf PSGallery gefunden."
        }

        $props = $response.properties | Select-Object -First 1
        $remoteVersion = [version]$props.Version

        $updateAvailable = $remoteVersion -gt $localVersion

        Invoke-sqmLogging -Message "Lokal: v$localVersion | PSGallery: v$remoteVersion | Update: $updateAvailable" -FunctionName $functionName -Level "INFO"

        return [PSCustomObject]@{
            Source          = 'PSGallery'
            UpdateAvailable = $updateAvailable
            LocalVersion    = $localVersion
            RemoteVersion   = $remoteVersion
            PublishedAt     = $props.Published
            Status          = 'OK'
        }
    }
    catch
    {
        $errMsg = "PSGallery-Pruefung fehlgeschlagen: $($_.Exception.Message)"
        Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
        if ($EnableException) { throw }
        return [PSCustomObject]@{
            Source          = 'PSGallery'
            UpdateAvailable = $false
            LocalVersion    = $null
            RemoteVersion   = $null
            Status          = 'Error'
            ErrorMessage    = $errMsg
        }
    }
}
