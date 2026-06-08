<#
.SYNOPSIS
    Checks if a newer version of sqmSQLTool is available on GitHub.

.DESCRIPTION
    Queries the GitHub Releases API for the latest release tag of sqmSQLTool
    and compares it with the locally installed version.
    Returns a PSCustomObject with UpdateAvailable, LocalVersion, RemoteVersion and DownloadUrl.

.PARAMETER Owner
    GitHub repository owner. Default: JankeUwe

.PARAMETER Repository
    GitHub repository name. Default: sqmSQLTool

.PARAMETER EnableException
    Throw exceptions immediately instead of returning error object.

.EXAMPLE
    Test-sqmUpdateViaGitHub

.EXAMPLE
    $result = Test-sqmUpdateViaGitHub
    if ($result.UpdateAvailable) { Write-Host "Update available: $($result.RemoteVersion)" }

.NOTES
    Requires internet access to api.github.com
    Uses Invoke-RestMethod (PS 5.1 compatible)
#>
function Test-sqmUpdateViaGitHub
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false)]
        [string]$Owner = 'JankeUwe',
        [Parameter(Mandatory = $false)]
        [string]$Repository = 'sqmSQLTool',
        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    $functionName = $MyInvocation.MyCommand.Name
    Invoke-sqmLogging -Message "Starte $functionName - Pruefe GitHub auf neue Version" -FunctionName $functionName -Level "INFO"

    try
    {
        # Lokale Version
        $localModule = Get-Module -Name sqmSQLTool -ErrorAction SilentlyContinue
        if (-not $localModule)
        {
            $localModule = Get-Module -ListAvailable -Name sqmSQLTool -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        $localVersion = if ($localModule) { [version]$localModule.Version } else { [version]'0.0.0.0' }

        # GitHub API abfragen
        $apiUrl = "https://api.github.com/repos/$Owner/$Repository/releases/latest"
        $headers = @{ 'User-Agent' = 'sqmSQLTool-UpdateCheck' }

        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop

        # Tag bereinigen (v1.4.7.0 -> 1.4.7.0)
        $tagName = $release.tag_name -replace '^v', ''
        $remoteVersion = [version]$tagName

        $downloadUrl = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -ExpandProperty browser_download_url -First 1
        if (-not $downloadUrl) { $downloadUrl = $release.zipball_url }

        $updateAvailable = $remoteVersion -gt $localVersion

        Invoke-sqmLogging -Message "Lokal: v$localVersion | GitHub: v$remoteVersion | Update: $updateAvailable" -FunctionName $functionName -Level "INFO"

        return [PSCustomObject]@{
            Source           = 'GitHub'
            UpdateAvailable  = $updateAvailable
            LocalVersion     = $localVersion
            RemoteVersion    = $remoteVersion
            DownloadUrl      = $downloadUrl
            ReleaseNotes     = $release.body
            PublishedAt      = $release.published_at
            Status           = 'OK'
        }
    }
    catch
    {
        $errMsg = "GitHub-Pruefung fehlgeschlagen: $($_.Exception.Message)"
        Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
        if ($EnableException) { throw }
        return [PSCustomObject]@{
            Source          = 'GitHub'
            UpdateAvailable = $false
            LocalVersion    = $null
            RemoteVersion   = $null
            DownloadUrl     = $null
            ReleaseNotes    = $null
            PublishedAt     = $null
            Status          = 'Error'
            ErrorMessage    = $errMsg
        }
    }
}
