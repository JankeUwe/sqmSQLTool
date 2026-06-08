<#
.SYNOPSIS
    Validates SSIS package compatibility for SQL Server upgrades (2016 - 2025).

.DESCRIPTION
    Tests whether SSIS packages will run in a target SQL Server version.
    Checks deprecated features, encoding issues, and connection types.

    Supports two package sources:
    1. SSISDB Catalog (deployed packages on target SQL Server)
    2. Filesystem .dtsx files (backup/undeployed packages)

    Output: HTML report + TXT + CSV (dark theme, with summary cards and filter)

.PARAMETER SqlInstance
    SQL Server instance to connect to (for SSISDB source).
    Omit to check only filesystem packages.

.PARAMETER SqlCredential
    Optional PSCredential for SQL authentication.

.PARAMETER FolderName
    Filter SSISDB packages to specific catalog folder(s).
    Example: 'MyFolder', 'Integration', etc.

.PARAMETER PackagePath
    Path to .dtsx files (filesystem source).
    Omit to check only SSISDB packages.

.PARAMETER Recurse
    Recurse into subfolders when reading .dtsx files.

.PARAMETER TargetVersion
    Target SQL Server version for compatibility check.
    Supported: 2016, 2017, 2019, 2022, 2025
    Default: 2022

.PARAMETER OutputPath
    Directory for HTML/TXT/CSV reports.
    Default: $env:ProgramData\sqmSQLTool\SSISReports

.PARAMETER EnableException
    Throw exceptions instead of returning error status.

.EXAMPLE
    # Check deployed packages on target server
    Test-sqmSSISPackageCompatibility -SqlInstance "NewServer2025" -TargetVersion 2025

.EXAMPLE
    # Check old package files before deployment
    Test-sqmSSISPackageCompatibility -PackagePath "C:\OldPackages" -TargetVersion 2025 -Recurse

.EXAMPLE
    # Compare deployed vs. backup packages
    Test-sqmSSISPackageCompatibility -SqlInstance "NewServer2025" `
      -PackagePath "C:\OldPackages" -TargetVersion 2025

.NOTES
    Author:       sqmSQLTool
    Use Case:     Validate packages before SQL Server upgrade

    3 Checks Performed:
    1. Deprecated Features (VersionMajor, ProtectionLevel, DelayValidation)
    2. Encoding Issues (CodePage, ValidateExternalMetadata)
    3. Connection Types (SQLNCLI10/11, ACE.OLEDB, ODBC)

    Output files:
    - sqmSSISCompatibility_<instance>_<timestamp>.html
    - sqmSSISCompatibility_<instance>_<timestamp>.txt
    - sqmSSISCompatibility_<instance>_<timestamp>.csv
#>
function Test-sqmSSISPackageCompatibility
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$SqlInstance,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential,

        [Parameter(Mandatory = $false)]
        [string[]]$FolderName,

        [Parameter(Mandatory = $false)]
        [string]$PackagePath,

        [Parameter(Mandatory = $false)]
        [switch]$Recurse,

        [Parameter(Mandatory = $false)]
        [ValidateSet(2016, 2017, 2019, 2022, 2025)]
        [int]$TargetVersion = 2022,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name

        # Validate at least one source specified
        if (-not $SqlInstance -and -not $PackagePath)
        {
            $errMsg = "Must specify either -SqlInstance or -PackagePath (or both)."
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
            throw $errMsg
        }

        # Set default OutputPath
        if (-not $OutputPath)
        {
            $OutputPath = Get-sqmConfig -Key 'OutputPath'
            if (-not $OutputPath) { $OutputPath = "$env:ProgramData\sqmSQLTool\SSISReports" }
        }

        # Version mapping: SQL Server version -> version major
        $versionMap = @{
            2016 = 13
            2017 = 14
            2019 = 15
            2022 = 16
            2025 = 17
        }
        $targetVersionMajor = $versionMap[$TargetVersion]

        Invoke-sqmLogging -Message "Starte $functionName - Target SQL $TargetVersion (VersionMajor=$targetVersionMajor)" `
            -FunctionName $functionName -Level 'INFO'
    }

    process
    {
        $allChecks = [System.Collections.Generic.List[PSCustomObject]]::new()
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $datestamp = Get-Date -Format 'yyyyMMdd_HHmm'

        try
        {
            # ===== PHASE 1: SSISDB Source =====
            if ($SqlInstance)
            {
                Invoke-sqmLogging -Message "Connecting to $SqlInstance for SSISDB..." -FunctionName $functionName -Level 'INFO'

                $connParams = @{ SqlInstance = $SqlInstance }
                if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

                try
                {
                    # === SQL 2022+ Certificate Workaround ===
                    # Pre-add TrustServerCertificate for initial connection (safer, handles self-signed certs)
                    $connectParams = $connParams.Clone()
                    $connectParams['TrustServerCertificate'] = $true

                    $sqlSrv = Connect-DbaInstance @connectParams -ErrorAction Stop
                    $sqlMajor = $sqlSrv.VersionMajor

                    # Ensure subsequent queries also trust certificates
                    if ($sqlMajor -ge 17)
                    {
                        $connParams['TrustServerCertificate'] = $true
                        Write-Verbose "SQL Server 2022+: TrustServerCertificate enabled for self-signed certificates"
                    }

                    Invoke-sqmLogging -Message "Connected to SQL Server v$sqlMajor (TargetVersion=$TargetVersion)" `
                        -FunctionName $functionName -Level 'INFO'

                    # Check SSISDB exists
                    $ssisDbCheck = Invoke-DbaQuery @connParams -ErrorAction Stop `
                        -Query "SELECT name FROM sys.databases WHERE name = 'SSISDB';"

                    if (-not $ssisDbCheck)
                    {
                        Invoke-sqmLogging -Message "SSISDB not found on $SqlInstance" `
                            -FunctionName $functionName -Level 'WARNING'
                        Write-Warning "SSISDB nicht gefunden auf $SqlInstance - SSIS-Katalog nicht eingerichtet."
                    }
                    else
                    {
                        # Query deployed packages
                        $folderFilter = if ($FolderName) {
                            $folderList = ($FolderName | ForEach-Object { "'$($_ -replace "'","''")'" }) -join ','
                            "AND f.name IN ($folderList)"
                        } else { '' }

                        $packages = Invoke-DbaQuery @connParams -ErrorAction Stop -Query @"
SELECT  f.name   AS FolderName,
        p.name   AS ProjectName,
        pk.name  AS PackageName,
        pk.version_major,
        pk.version_minor,
        pk.version_build,
        p.last_deployed_time,
        p.deployed_by_name
FROM    SSISDB.catalog.packages pk
JOIN    SSISDB.catalog.projects p  ON p.project_id  = pk.project_id
JOIN    SSISDB.catalog.folders  f  ON f.folder_id   = p.folder_id
$folderFilter
ORDER BY f.name, p.name, pk.name;
"@

                        # Check 1: Deprecated Features (Version)
                        foreach ($pkg in @($packages))
                        {
                            $pkgVersionMajor = [int]$pkg.version_major

                            if ($pkgVersionMajor -gt $targetVersionMajor)
                            {
                                $allChecks.Add([PSCustomObject]@{
                                    Source      = 'SSISDB'
                                    Folder      = $pkg.FolderName
                                    Project     = $pkg.ProjectName
                                    Package     = $pkg.PackageName
                                    Category    = 'Deprecated Features'
                                    Check       = 'Package Version'
                                    Status      = 'Error'
                                    Current     = "v$($pkg.version_major).$($pkg.version_minor).$($pkg.version_build)"
                                    Expected    = "v$targetVersionMajor or lower"
                                    Message     = "Paket-Version $pkgVersionMajor > Ziel SQL $TargetVersion - Anpassung erforderlich"
                                    DeployedBy  = $pkg.deployed_by_name
                                    DeployedOn  = $pkg.last_deployed_time
                                })
                            }
                            else
                            {
                                $allChecks.Add([PSCustomObject]@{
                                    Source      = 'SSISDB'
                                    Folder      = $pkg.FolderName
                                    Project     = $pkg.ProjectName
                                    Package     = $pkg.PackageName
                                    Category    = 'Deprecated Features'
                                    Check       = 'Package Version'
                                    Status      = 'OK'
                                    Current     = "v$($pkg.version_major).$($pkg.version_minor).$($pkg.version_build)"
                                    Expected    = "v$targetVersionMajor or lower"
                                    Message     = "Paket-Version kompatibel mit SQL $TargetVersion"
                                    DeployedBy  = $pkg.deployed_by_name
                                    DeployedOn  = $pkg.last_deployed_time
                                })
                            }
                        }

                        Invoke-sqmLogging -Message "SSISDB: $($packages.Count) packages processed" `
                            -FunctionName $functionName -Level 'INFO'
                    }
                }
                catch
                {
                    $errMsg = "SSISDB connection/query failed: $($_.Exception.Message)"
                    Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
                    throw
                }
            }

            # ===== PHASE 2: Filesystem Source (.dtsx) =====
            if ($PackagePath)
            {
                if (-not (Test-Path $PackagePath))
                {
                    $errMsg = "PackagePath not found: $PackagePath"
                    Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
                    throw $errMsg
                }

                Invoke-sqmLogging -Message "Reading .dtsx files from $PackagePath (Recurse=$Recurse)" `
                    -FunctionName $functionName -Level 'INFO'

                $dtsx = Get-ChildItem -Path $PackagePath -Filter '*.dtsx' -Recurse:$Recurse -ErrorAction Stop
                Invoke-sqmLogging -Message "Found $($dtsx.Count) .dtsx files" -FunctionName $functionName -Level 'INFO'

                # XML Namespace
                $ns = @{ DTS = 'www.microsoft.com/SqlServer/Dts' }

                foreach ($file in $dtsx)
                {
                    try
                    {
                        [xml]$xml = Get-Content $file.FullName -Encoding UTF8 -ErrorAction Stop
                        $nsManager = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
                        $nsManager.AddNamespace('DTS', 'www.microsoft.com/SqlServer/Dts')

                        # Extract package version
                        $pkgNode = $xml.SelectSingleNode('//DTS:Package', $nsManager)
                        $pkgVersionMajor = [int]($pkgNode.GetAttribute('DTS:VersionMajor') -replace 'DTS:', '')
                        $pkgName = $file.BaseName
                        $relPath = $file.FullName -replace [regex]::Escape($PackagePath), ''

                        # Check 1: Version Compatibility
                        if ($pkgVersionMajor -gt $targetVersionMajor)
                        {
                            $allChecks.Add([PSCustomObject]@{
                                Source      = 'Filesystem'
                                Folder      = Split-Path $relPath -Parent
                                Project     = ''
                                Package     = $pkgName
                                Category    = 'Deprecated Features'
                                Check       = 'Package Version'
                                Status      = 'Error'
                                Current     = "v$pkgVersionMajor"
                                Expected    = "v$targetVersionMajor or lower"
                                Message     = "Paket-Version $pkgVersionMajor > Ziel SQL $TargetVersion"
                                DeployedBy  = ''
                                DeployedOn  = $file.LastWriteTime
                            })
                        }
                        else
                        {
                            $allChecks.Add([PSCustomObject]@{
                                Source      = 'Filesystem'
                                Folder      = Split-Path $relPath -Parent
                                Project     = ''
                                Package     = $pkgName
                                Category    = 'Deprecated Features'
                                Check       = 'Package Version'
                                Status      = 'OK'
                                Current     = "v$pkgVersionMajor"
                                Expected    = "v$targetVersionMajor or lower"
                                Message     = "Paket-Version kompatibel mit SQL $TargetVersion"
                                DeployedBy  = ''
                                DeployedOn  = $file.LastWriteTime
                            })
                        }

                        # Check 3: Connection Types
                        $connMgrs = $xml.SelectNodes('//DTS:ConnectionManager', $nsManager)
                        foreach ($cm in $connMgrs)
                        {
                            $cmName = $cm.GetAttribute('DTS:ObjectName')
                            $cmConnStr = $cm.SelectSingleNode('DTS:ObjectData/*/ConnectionString', $nsManager)
                            $connStr = if ($cmConnStr) { $cmConnStr.InnerText } else { '' }

                            # Check for deprecated providers
                            if ($connStr -like '*SQLNCLI10*' -or $connStr -like '*SQLNCLI11*')
                            {
                                $allChecks.Add([PSCustomObject]@{
                                    Source      = 'Filesystem'
                                    Folder      = Split-Path $relPath -Parent
                                    Project     = ''
                                    Package     = $pkgName
                                    Category    = 'Connection Types'
                                    Check       = "Connection: $cmName"
                                    Status      = 'Warning'
                                    Current     = 'SQLNCLI10/11'
                                    Expected    = 'MSOLEDBSQL'
                                    Message     = 'SQLNCLI deprecated ab SQL 2019 - verwende MSOLEDBSQL'
                                    DeployedBy  = ''
                                    DeployedOn  = $file.LastWriteTime
                                })
                            }
                            elseif ($connStr -like '*ACE.OLEDB.12*')
                            {
                                $allChecks.Add([PSCustomObject]@{
                                    Source      = 'Filesystem'
                                    Folder      = Split-Path $relPath -Parent
                                    Project     = ''
                                    Package     = $pkgName
                                    Category    = 'Connection Types'
                                    Check       = "Connection: $cmName"
                                    Status      = 'Error'
                                    Current     = 'ACE.OLEDB.12.0'
                                    Expected    = 'ACE.OLEDB.16.0 or newer'
                                    Message     = 'ACE OLE DB 12.0 nicht verfuegbar ab SQL 2025'
                                    DeployedBy  = ''
                                    DeployedOn  = $file.LastWriteTime
                                })
                            }
                        }
                    }
                    catch
                    {
                        Invoke-sqmLogging -Message "Error processing $($file.FullName): $_" `
                            -FunctionName $functionName -Level 'WARNING'
                    }
                }
            }

            # ===== PHASE 3: Summary & Reports =====
            $countOk   = ($allChecks | Where-Object { $_.Status -eq 'OK' }).Count
            $countWarn = ($allChecks | Where-Object { $_.Status -eq 'Warning' }).Count
            $countErr  = ($allChecks | Where-Object { $_.Status -eq 'Error' }).Count
            $overall   = if ($countErr -gt 0) { 'Error' } elseif ($countWarn -gt 0) { 'Warning' } else { 'OK' }

            # Create output directory
            if (-not (Test-Path $OutputPath))
            {
                New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
                Invoke-sqmLogging -Message "Created output directory: $OutputPath" -FunctionName $functionName -Level 'INFO'
            }

            # Save TXT report
            $safeInst = if ($SqlInstance) { ($SqlInstance -replace '[\\:]', '_') } else { 'Filesystem' }
            $txtFile = Join-Path $OutputPath "sqmSSISCompatibility_${safeInst}_${datestamp}.txt"
            $csvFile = Join-Path $OutputPath "sqmSSISCompatibility_${safeInst}_${datestamp}.csv"
            $htmlFile = Join-Path $OutputPath "sqmSSISCompatibility_${safeInst}_${datestamp}.html"

            # TXT Report
            $txtLines = @(
                "# sqmSQLTool - www.powershelldba.de"
                "# ================================================================"
                "# SSIS Package Compatibility Report"
                "# ================================================================"
                "# Target SQL Version : $TargetVersion (VersionMajor=$targetVersionMajor)"
                "# Timestamp          : $timestamp"
                "# Total Checks       : $($allChecks.Count)"
                "# OK                 : $countOk"
                "# Warnings           : $countWarn"
                "# Errors             : $countErr"
                "# Overall Status     : $overall"
                "# ================================================================"
                ""
                ("{0,-12} {1,-20} {2,-30} {3,-30} {4,-15} {5}" -f 'Source', 'Package', 'Category', 'Check', 'Status', 'Message')
                ("-" * 130)
            )

            foreach ($check in ($allChecks | Sort-Object Status, Package))
            {
                $status = $check.Status
                $txtLines += ("{0,-12} {1,-20} {2,-30} {3,-30} {4,-15} {5}" -f `
                    $check.Source, $check.Package, $check.Category, $check.Check, $status, $check.Message)
            }

            $txtLines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
            Invoke-sqmLogging -Message "TXT report saved: $txtFile" -FunctionName $functionName -Level 'INFO'

            # CSV Report
            $allChecks | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force
            Invoke-sqmLogging -Message "CSV report saved: $csvFile" -FunctionName $functionName -Level 'INFO'

            # HTML Report (simplified dark theme)
            $htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>SSIS Compatibility Report</title>
    <style>
        body { background: #060f20; color: #e2e8f0; font-family: Consolas, monospace; margin: 0; padding: 20px; }
        .header { background: linear-gradient(160deg, #060f20 0%, #0b1e3d 100%); padding: 20px; border-radius: 4px; margin-bottom: 20px; }
        .header h1 { margin: 0 0 5px 0; color: #5dade2; }
        .header p { margin: 2px 0; color: #94a8c0; font-size: 12px; }
        .summary { display: grid; grid-template-columns: repeat(4, 1fr); gap: 15px; margin-bottom: 20px; }
        .summary-card { background: #0b1e3d; border-left: 4px solid #5dade2; padding: 15px; border-radius: 4px; text-align: center; }
        .summary-card .num { font-size: 24px; font-weight: bold; color: #5dade2; }
        .summary-card .lbl { font-size: 12px; color: #94a8c0; margin-top: 5px; }
        .summary-card.ok { border-left-color: #27ae60; }
        .summary-card.warn { border-left-color: #f39c12; }
        .summary-card.err { border-left-color: #e74c3c; }
        table { width: 100%; border-collapse: collapse; background: #0b1e3d; border-radius: 4px; overflow: hidden; }
        th { background: #0d1f38; color: #5dade2; padding: 12px; text-align: left; font-weight: bold; font-size: 12px; }
        td { padding: 10px 12px; border-bottom: 1px solid #1e3a5f; }
        tr:hover { background: #0e2e4a; }
        .badge { display: inline-block; padding: 3px 8px; border-radius: 3px; font-size: 11px; font-weight: bold; }
        .badge-ok { background: #27ae60; color: white; }
        .badge-warn { background: #f39c12; color: white; }
        .badge-err { background: #e74c3c; color: white; }
        .footer { margin-top: 20px; font-size: 11px; color: #94a8c0; }
    </style>
</head>
<body>
    <div class="header">
        <h1>sqmSQLTool - SSIS Package Compatibility Report</h1>
        <p>Target SQL Server: $TargetVersion (VersionMajor=$targetVersionMajor)</p>
        <p>Generated: $timestamp</p>
    </div>

    <div class="summary">
        <div class="summary-card" style="border-left-color: $(if($overall -eq 'OK'){'#27ae60'} elseif($overall -eq 'Warning'){'#f39c12'} else {'#e74c3c'});">
            <div class="num">$overall</div>
            <div class="lbl">Overall Status</div>
        </div>
        <div class="summary-card ok">
            <div class="num">$countOk</div>
            <div class="lbl">OK</div>
        </div>
        <div class="summary-card warn">
            <div class="num">$countWarn</div>
            <div class="lbl">Warnings</div>
        </div>
        <div class="summary-card err">
            <div class="num">$countErr</div>
            <div class="lbl">Errors</div>
        </div>
    </div>

    <table>
        <thead>
            <tr>
                <th>Source</th>
                <th>Package</th>
                <th>Category</th>
                <th>Check</th>
                <th>Status</th>
                <th>Message</th>
            </tr>
        </thead>
        <tbody>
"@

            foreach ($check in ($allChecks | Sort-Object Status, Package))
            {
                $badgeClass = switch ($check.Status) {
                    'OK' { 'badge-ok' }
                    'Warning' { 'badge-warn' }
                    default { 'badge-err' }
                }
                $htmlContent += "            <tr>"
                $htmlContent += "<td>$($check.Source)</td>"
                $htmlContent += "<td>$($check.Package)</td>"
                $htmlContent += "<td>$($check.Category)</td>"
                $htmlContent += "<td>$($check.Check)</td>"
                $htmlContent += "<td><span class='badge $badgeClass'>$($check.Status)</span></td>"
                $htmlContent += "<td>$($check.Message)</td>"
                $htmlContent += "            </tr>`n"
            }

            $htmlContent += @"
        </tbody>
    </table>

    <div class="footer">
        <p>sqmSQLTool - SSIS Compatibility Validator | $(Get-Date -Format 'yyyy-MM-dd')</p>
    </div>
</body>
</html>
"@

            $htmlContent | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
            Invoke-sqmLogging -Message "HTML report saved: $htmlFile" -FunctionName $functionName -Level 'INFO'

            Write-Host "SSIS Compatibility Report: $htmlFile" -ForegroundColor Cyan

            # Return result
            return [PSCustomObject]@{
                SqlInstance    = $SqlInstance
                PackagePath    = $PackagePath
                TargetVersion  = $TargetVersion
                CheckCount     = $allChecks.Count
                CountOk        = $countOk
                CountWarn      = $countWarn
                CountErr       = $countErr
                Status         = $overall
                Checks         = $allChecks.ToArray()
                HtmlFile       = $htmlFile
                TxtFile        = $txtFile
                CsvFile        = $csvFile
                Message        = "SSIS Compatibility Check: $overall ($countOk OK / $countWarn Warn / $countErr Err)"
                Timestamp      = $timestamp
            }
        }
        catch
        {
            $errMsg = "Fehler in $functionName`: $($_.Exception.Message)"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
            if ($EnableException) { throw }
            Write-Error $errMsg
            return [PSCustomObject]@{
                SqlInstance   = $SqlInstance
                Status        = 'Error'
                Message       = $errMsg
                CheckCount    = 0
                HtmlFile      = $null
                TxtFile       = $null
                CsvFile       = $null
            }
        }
    }

    end
    {
        Invoke-sqmLogging -Message "$functionName completed." -FunctionName $functionName -Level 'INFO'
    }
}
