<#
.SYNOPSIS
    Checks if a newer version of sqmSQLTool is available on a UNC share.

.DESCRIPTION
    Compares the locally installed sqmSQLTool version with the version in the
    specified UNC share. Reads ModuleVersion.txt or sqmSQLTool.psd1 from the share.

.PARAMETER RepositoryPath
    UNC path to the sqmSQLTool repository share.
    Default: W:\75084-Datenbanken\MSSQL\DEV\sqmSQLTool

.PARAMETER EnableException
    Throw exceptions immediately instead of returning error object.

.EXAMPLE
    Test-sqmUpdateViaUNC

.EXAMPLE
    Test-sqmUpdateViaUNC -RepositoryPath "\\fileserver\dba\sqmSQLTool"

.NOTES
    Requires network access to the UNC share.
    Reads ModuleVersion.txt or sqmSQLTool.psd1 to determine remote version.
#>
function Test-sqmUpdateViaUNC
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false)]
        [string]$RepositoryPath = 'W:\75084-Datenbanken\MSSQL\DEV\sqmSQLTool',
        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    $functionName = $MyInvocation.MyCommand.Name
    Invoke-sqmLogging -Message "Starte $functionName - Pruefe UNC-Share: $RepositoryPath" -FunctionName $functionName -Level "INFO"

    try
    {
        # Share erreichbar?
        if (-not (Test-Path $RepositoryPath))
        {
            throw "UNC-Share nicht erreichbar: $RepositoryPath"
        }

        # Lokale Version
        $localModule = Get-Module -Name sqmSQLTool -ErrorAction SilentlyContinue
        if (-not $localModule)
        {
            $localModule = Get-Module -ListAvailable -Name sqmSQLTool -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        $localVersion = if ($localModule) { [version]$localModule.Version } else { [version]'0.0.0.0' }

        # Remote Version aus ModuleVersion.txt oder psd1
        $remoteVersion = $null
        $versionFile = Join-Path $RepositoryPath 'ModuleVersion.txt'
        $remoteManifest = Join-Path $RepositoryPath 'sqmSQLTool.psd1'

        if (Test-Path $versionFile)
        {
            $remoteVersion = [version](Get-Content $versionFile -ErrorAction Stop).Trim()
        }
        elseif (Test-Path $remoteManifest)
        {
            $remoteVersion = [version](Import-PowerShellDataFile $remoteManifest -ErrorAction Stop).ModuleVersion
        }
        else
        {
            throw "Keine Versionsinformation im Share gefunden (ModuleVersion.txt oder sqmSQLTool.psd1)."
        }

        $updateAvailable = $remoteVersion -gt $localVersion

        Invoke-sqmLogging -Message "Lokal: v$localVersion | UNC: v$remoteVersion | Update: $updateAvailable" -FunctionName $functionName -Level "INFO"

        return [PSCustomObject]@{
            Source           = 'UNC'
            UpdateAvailable  = $updateAvailable
            LocalVersion     = $localVersion
            RemoteVersion    = $remoteVersion
            RepositoryPath   = $RepositoryPath
            Status           = 'OK'
        }
    }
    catch
    {
        $errMsg = "UNC-Pruefung fehlgeschlagen: $($_.Exception.Message)"
        Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
        if ($EnableException) { throw }
        return [PSCustomObject]@{
            Source          = 'UNC'
            UpdateAvailable = $false
            LocalVersion    = $null
            RemoteVersion   = $null
            RepositoryPath  = $RepositoryPath
            Status          = 'Error'
            ErrorMessage    = $errMsg
        }
    }
}
