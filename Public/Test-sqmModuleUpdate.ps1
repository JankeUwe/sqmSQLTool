<#
.SYNOPSIS
    Checks all configured update sources for a newer sqmSQLTool version.

.DESCRIPTION
    Checks GitHub, PSGallery and/or a UNC share for newer versions of sqmSQLTool.
    Returns combined results from all reachable sources.
    Use -Source to limit the check to specific sources.

.PARAMETER Source
    Which sources to check. Valid values: GitHub, PSGallery, UNC, All.
    Default: All

.PARAMETER RepositoryPath
    UNC path for the UNC source check.
    Default: W:\75084-Datenbanken\MSSQL\DEV\sqmSQLTool

.PARAMETER EnableException
    Throw exceptions immediately instead of returning error object.

.EXAMPLE
    Test-sqmModuleUpdate

.EXAMPLE
    Test-sqmModuleUpdate -Source GitHub

.EXAMPLE
    Test-sqmModuleUpdate -Source UNC -RepositoryPath "\\fileserver\dba\sqmSQLTool"

.NOTES
    Calls Test-sqmUpdateViaGitHub, Test-sqmUpdateViaPSGallery and/or Test-sqmUpdateViaUNC.
    Returns array of result objects, one per source checked.
#>
function Test-sqmModuleUpdate
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false)]
        [ValidateSet('GitHub', 'PSGallery', 'UNC', 'All')]
        [string]$Source = 'All',
        [Parameter(Mandatory = $false)]
        [string]$RepositoryPath = 'W:\75084-Datenbanken\MSSQL\DEV\sqmSQLTool',
        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    $functionName = $MyInvocation.MyCommand.Name
    Invoke-sqmLogging -Message "Starte $functionName - Source: $Source" -FunctionName $functionName -Level "INFO"

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($Source -eq 'GitHub' -or $Source -eq 'All')
    {
        $r = Test-sqmUpdateViaGitHub -EnableException:$EnableException
        $results.Add($r)
    }

    if ($Source -eq 'PSGallery' -or $Source -eq 'All')
    {
        $r = Test-sqmUpdateViaPSGallery -EnableException:$EnableException
        $results.Add($r)
    }

    if ($Source -eq 'UNC' -or $Source -eq 'All')
    {
        $r = Test-sqmUpdateViaUNC -RepositoryPath $RepositoryPath -EnableException:$EnableException
        $results.Add($r)
    }

    # Zusammenfassung ausgeben
    foreach ($result in $results)
    {
        if ($result.Status -eq 'OK')
        {
            if ($result.UpdateAvailable)
            {
                Write-Host "[$($result.Source)] Update verfuegbar: v$($result.LocalVersion) -> v$($result.RemoteVersion)" -ForegroundColor Yellow
            }
            else
            {
                Write-Host "[$($result.Source)] Aktuell: v$($result.LocalVersion)" -ForegroundColor Green
            }
        }
        else
        {
            Write-Host "[$($result.Source)] Fehler: $($result.ErrorMessage)" -ForegroundColor Red
        }
    }

    return $results.ToArray()
}
