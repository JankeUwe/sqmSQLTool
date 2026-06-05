<#
.SYNOPSIS
    Updates the sqmSQLTool module from GitHub, PSGallery or a UNC share.

.DESCRIPTION
    Downloads and installs the latest version of sqmSQLTool from the specified source.

    Process:
    1. Check if update is available (via Test-sqmModuleUpdate)
    2. Create backup of current installation
    3. Download/copy new version
    4. Unblock all files (remove Zone.Identifier ADS)
    5. Verify import succeeds
    6. Report installed version

    Sources:
    - GitHub  : Downloads latest release ZIP from GitHub Releases
    - PSGallery: Installs via Install-Module / Update-Module
    - UNC     : Copies from share using robocopy (same as Update.ps1)

.PARAMETER Source
    Update source. Valid values: GitHub, PSGallery, UNC.
    Default: GitHub

.PARAMETER RepositoryPath
    UNC path for UNC source.
    Default: W:\75084-Datenbanken\MSSQL\DEV\sqmSQLTool

.PARAMETER Destination
    Installation path for the module.
    Default: C:\Windows\System32\WindowsPowerShell\v1.0\Modules\sqmSQLTool
    (or %ProgramFiles%\WindowsPowerShell\Modules\sqmSQLTool)

.PARAMETER Force
    Install even if no newer version is available.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Update-sqmModule

.EXAMPLE
    Update-sqmModule -Source GitHub -Force

.EXAMPLE
    Update-sqmModule -Source UNC -RepositoryPath "\\fileserver\dba\sqmSQLTool"

.NOTES
    Requires administrator rights for installation to Program Files.
    GitHub source requires internet access.
    UNC source requires network access to the share.
#>
function Update-sqmModule
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false)]
        [ValidateSet('GitHub', 'PSGallery', 'UNC')]
        [string]$Source = 'GitHub',
        [Parameter(Mandatory = $false)]
        [string]$RepositoryPath = 'W:\75084-Datenbanken\MSSQL\DEV\sqmSQLTool',
        [Parameter(Mandatory = $false)]
        [string]$Destination = "$env:ProgramFiles\WindowsPowerShell\Modules\sqmSQLTool",
        [Parameter(Mandatory = $false)]
        [switch]$Force,
        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    $functionName = $MyInvocation.MyCommand.Name
    Invoke-sqmLogging -Message "Starte $functionName - Source: $Source" -FunctionName $functionName -Level "INFO"

    try
    {
        # ---------------------------------------------------------------
        # 1. Update pruefen
        # ---------------------------------------------------------------
        $checkResult = switch ($Source)
        {
            'GitHub'    { Test-sqmUpdateViaGitHub -EnableException:$EnableException }
            'PSGallery' { Test-sqmUpdateViaPSGallery -EnableException:$EnableException }
            'UNC'       { Test-sqmUpdateViaUNC -RepositoryPath $RepositoryPath -EnableException:$EnableException }
        }

        if ($checkResult.Status -ne 'OK')
        {
            throw "Versionspruefung fehlgeschlagen: $($checkResult.ErrorMessage)"
        }

        if (-not $Force -and -not $checkResult.UpdateAvailable)
        {
            Write-Host "sqmSQLTool ist bereits aktuell (v$($checkResult.LocalVersion))." -ForegroundColor Green
            return [PSCustomObject]@{
                Status         = 'UpToDate'
                LocalVersion   = $checkResult.LocalVersion
                RemoteVersion  = $checkResult.RemoteVersion
            }
        }

        $action = "sqmSQLTool v$($checkResult.LocalVersion) -> v$($checkResult.RemoteVersion) via $Source"
        if (-not $PSCmdlet.ShouldProcess('sqmSQLTool', $action)) { return $null }

        # ---------------------------------------------------------------
        # 2. Backup
        # ---------------------------------------------------------------
        if (Test-Path $Destination)
        {
            $backupDir = "$Destination`_Backup_$(Get-Date -Format 'yyyyMMdd_HHmm')"
            Invoke-sqmLogging -Message "Erstelle Backup: $backupDir" -FunctionName $functionName -Level "INFO"
            Copy-Item -Path $Destination -Destination $backupDir -Recurse -Force
        }

        # ---------------------------------------------------------------
        # 3. Update installieren
        # ---------------------------------------------------------------
        switch ($Source)
        {
            'GitHub'
            {
                if (-not $checkResult.DownloadUrl)
                {
                    throw "Kein Download-URL in GitHub Release gefunden."
                }

                $tmpZip = Join-Path $env:TEMP "sqmSQLTool_update.zip"
                $tmpDir = Join-Path $env:TEMP "sqmSQLTool_update"

                Invoke-sqmLogging -Message "Lade herunter: $($checkResult.DownloadUrl)" -FunctionName $functionName -Level "INFO"
                Invoke-WebRequest -Uri $checkResult.DownloadUrl -OutFile $tmpZip -UseBasicParsing -ErrorAction Stop

                if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
                Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force

                # Modul-Ordner im ZIP finden
                $moduleFolder = Get-ChildItem $tmpDir -Recurse -Filter 'sqmSQLTool.psd1' | Select-Object -First 1 | Split-Path -Parent
                if (-not $moduleFolder) { throw "sqmSQLTool.psd1 nicht im ZIP gefunden." }

                if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
                Copy-Item -Path "$moduleFolder\*" -Destination $Destination -Recurse -Force

                # Aufraumen
                Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
                Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }

            'PSGallery'
            {
                $installedModule = Get-Module -ListAvailable -Name sqmSQLTool -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($installedModule)
                {
                    Invoke-sqmLogging -Message "Update-Module sqmSQLTool via PSGallery" -FunctionName $functionName -Level "INFO"
                    Update-Module -Name sqmSQLTool -Force -ErrorAction Stop
                }
                else
                {
                    Invoke-sqmLogging -Message "Install-Module sqmSQLTool via PSGallery" -FunctionName $functionName -Level "INFO"
                    Install-Module -Name sqmSQLTool -Force -ErrorAction Stop
                }
            }

            'UNC'
            {
                Invoke-sqmLogging -Message "Kopiere von UNC: $RepositoryPath" -FunctionName $functionName -Level "INFO"
                & robocopy $RepositoryPath $Destination /E /NJH /NJS /NDL /COPY:DAT /XD .git /XF .gitignore README.md LICENSE Install.cmd Install.ps1 Update.cmd Update.ps1
                if ($LASTEXITCODE -ge 8)
                {
                    throw "robocopy fehlgeschlagen (ExitCode $LASTEXITCODE)"
                }
            }
        }

        # ---------------------------------------------------------------
        # 4. Zone.Identifier entfernen
        # ---------------------------------------------------------------
        Get-ChildItem -Path $Destination -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue
        }

        # ---------------------------------------------------------------
        # 5. Import testen
        # ---------------------------------------------------------------
        Remove-Module sqmSQLTool -ErrorAction SilentlyContinue
        Import-Module sqmSQLTool -Force -ErrorAction Stop
        $newVersion = (Get-Module sqmSQLTool).Version

        Invoke-sqmLogging -Message "sqmSQLTool v$newVersion erfolgreich installiert." -FunctionName $functionName -Level "INFO"
        Write-Host "sqmSQLTool v$newVersion erfolgreich aktualisiert." -ForegroundColor Green

        return [PSCustomObject]@{
            Status         = 'Updated'
            Source         = $Source
            OldVersion     = $checkResult.LocalVersion
            NewVersion     = $newVersion
            Destination    = $Destination
            BackupPath     = if ($backupDir) { $backupDir } else { $null }
        }
    }
    catch
    {
        $errMsg = "Update fehlgeschlagen: $($_.Exception.Message)"
        Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
        if ($EnableException) { throw }
        Write-Error $errMsg
        return [PSCustomObject]@{
            Status       = 'Failed'
            Source       = $Source
            ErrorMessage = $errMsg
        }
    }
}
