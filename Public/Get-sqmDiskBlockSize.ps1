<#
.SYNOPSIS
    Checks the NTFS block size (cluster size) of drives against 64KB.

.DESCRIPTION
    Reads the NTFS allocation unit (block size) of the specified drives via
    WMI (Win32_Volume) and checks whether the 64 KB (65536 bytes) recommended
    for SQL Server is configured.

    Can either check individual drive letters directly, or automatically
    discover all drives used by a SQL Server instance (Data, Log, Backup,
    TempDB).

    Read-only access - makes no changes to the system.
    To format: Invoke-sqmFormatDrive64k

.PARAMETER Drive
    Drive letter(s) without a colon, e.g. 'F', 'G', 'H'.
    Pipeline-capable. If not provided: -SqlInstance must be set.

.PARAMETER SqlInstance
    SQL Server instance. When provided, all drives used by SQL Server (Data,
    Log, Backup, TempDB) are automatically discovered from the registry.

.PARAMETER ComputerName
    Target computer for the WMI query. Default: local computer.

.PARAMETER RecommendedBlockSize
    Recommended block size in bytes. Default: 65536 (64 KB).

.PARAMETER EnableException
    Throw exceptions immediately instead of Write-Error.

.OUTPUTS
    [PSCustomObject] per drive with the fields:
        Drive                : Drive letter
        Path                 : Full path (e.g. F:\)
        Label                : Volume label
        BlockSize            : Current block size in bytes
        BlockSizeKB          : Current block size in KB
        RecommendedBlockSize : Recommended block size in bytes
        IsRecommended        : $true if the block size is correct
        Status               : OK | Warning | NotNTFS | Error
        Message              : Detail message

.EXAMPLE
    # Check individual drives
    Get-sqmDiskBlockSize -Drive 'F', 'G', 'H'

.EXAMPLE
    # Automatically discover and check all SQL drives of the instance
    Get-sqmDiskBlockSize -SqlInstance "SQL01"

.EXAMPLE
    # Pipeline
    'F','G' | Get-sqmDiskBlockSize

.EXAMPLE
    # Only show drives with an incorrect block size
    Get-sqmDiskBlockSize -SqlInstance "SQL01" | Where-Object { -not $_.IsRecommended }

.NOTES
    SQL Server recommendation: 64 KB NTFS allocation unit for all data drives.
    Default Windows format: 4 KB - not optimal for SQL Server.
    Does not apply to system/OS drives (C:\).
    To format with 64 KB: Invoke-sqmFormatDrive64k
#>
function Get-sqmDiskBlockSize
{
    [CmdletBinding(DefaultParameterSetName = 'ByDrive')]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'ByDrive',
                   ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true,
                   Position = 0)]
        [ValidatePattern('^[A-Za-z]$')]
        [string[]]$Drive,

        [Parameter(Mandatory = $true, ParameterSetName = 'BySqlInstance')]
        [string]$SqlInstance,

        [Parameter(Mandatory = $false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory = $false)]
        [ValidateSet(4096, 8192, 16384, 32768, 65536, 131072)]
        [int]$RecommendedBlockSize = 65536,

        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin
    {
        $functionName  = $MyInvocation.MyCommand.Name
        $drivesToCheck = [System.Collections.Generic.List[string]]::new()

        # Empfohlene Blockgroesse aus Modulkonfiguration lesen (ueberschreibt Parameter-Default wenn nicht explizit angegeben)
        if (-not $PSBoundParameters.ContainsKey('RecommendedBlockSize'))
        {
            $cfgVal = Get-sqmConfig -Key 'CheckDiskBlockSize'
            if ($null -ne $cfgVal) { $RecommendedBlockSize = [int]$cfgVal }
        }

        Invoke-sqmLogging -Message "Starte $functionName auf $ComputerName (Empfehlung: $([Math]::Round($RecommendedBlockSize/1024)) KB)" -FunctionName $functionName -Level 'INFO'

        # Hilfsfunktion: WMI-Abfrage fuer ein Laufwerk
        function _GetVolumeInfo
        {
            param ([string]$DriveLetter, [string]$Computer)
            $path = "$($DriveLetter.ToUpper()):\\"
            $wql  = "SELECT Name, Label, BlockSize FROM Win32_Volume WHERE FileSystem='NTFS' AND Name='$path'"
            try
            {
                Get-WmiObject -Query $wql -ComputerName $Computer -ErrorAction Stop
            }
            catch
            {
                $null
            }
        }

        # Bei BySqlInstance: Laufwerke aus Registry ermitteln
        if ($PSCmdlet.ParameterSetName -eq 'BySqlInstance')
        {
            try
            {
                Invoke-sqmLogging -Message "Ermittle SQL-Laufwerke fuer $SqlInstance aus Registry." -FunctionName $functionName -Level 'INFO'

                $instances = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' `
                    -ErrorAction Stop).PSObject.Properties |
                    Where-Object { $_.Name -notmatch '^PS' }

                foreach ($inst in $instances)
                {
                    $regKey = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($inst.Value)\MSSQLServer" `
                        -ErrorAction SilentlyContinue

                    foreach ($prop in @('BackupDirectory', 'DefaultData', 'DefaultLog'))
                    {
                        $val = ($regKey.PSObject.Properties | Where-Object { $_.Name -eq $prop }).Value
                        if ($val -match '^([A-Za-z]):')
                        {
                            $drivesToCheck.Add($Matches[1].ToUpper()) | Out-Null
                        }
                    }
                }

                # TempDB-Laufwerke via SMO
                [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.Smo')
                $smo = New-Object Microsoft.SqlServer.Management.Smo.Server($SqlInstance)
                $smo.Databases['tempdb'].FileGroups | ForEach-Object { $_.Files } | ForEach-Object {
                    if ($_.FileName -match '^([A-Za-z]):')
                    {
                        $drivesToCheck.Add($Matches[1].ToUpper()) | Out-Null
                    }
                }

                $drivesToCheck = ($drivesToCheck | Sort-Object -Unique)
                Invoke-sqmLogging -Message "SQL-Laufwerke ermittelt: $($drivesToCheck -join ', ')" -FunctionName $functionName -Level 'INFO'
            }
            catch
            {
                $errMsg = "Fehler beim Ermitteln der SQL-Laufwerke: $($_.Exception.Message)"
                Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
                if ($EnableException) { throw }
                Write-Error $errMsg
                return
            }
        }
    }

    process
    {
        # ByDrive: Laufwerke aus Pipeline/Parameter sammeln
        if ($PSCmdlet.ParameterSetName -eq 'ByDrive')
        {
            foreach ($d in $Drive)
            {
                $drivesToCheck.Add($d.ToUpper()) | Out-Null
            }
        }
    }

    end
    {
        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($d in ($drivesToCheck | Sort-Object -Unique))
        {
            try
            {
                $vol = _GetVolumeInfo -DriveLetter $d -Computer $ComputerName

                if (-not $vol)
                {
                    $status  = 'NotNTFS'
                    $message = "Laufwerk ${d}: nicht gefunden oder kein NTFS-Volume."
                    Write-Host "  ---- Laufwerk ${d}: $message" -ForegroundColor DarkGray
                    Invoke-sqmLogging -Message $message -FunctionName $functionName -Level 'WARNING'

                    $results.Add([PSCustomObject]@{
                        Drive                = $d
                        Path                 = "${d}:\"
                        Label                = $null
                        BlockSize            = $null
                        BlockSizeKB          = $null
                        RecommendedBlockSize = $RecommendedBlockSize
                        IsRecommended        = $false
                        Status               = $status
                        Message              = $message
                    })
                    continue
                }

                $blockSize   = [int]$vol.BlockSize
                $blockSizeKB = [Math]::Round($blockSize / 1024, 0)
                $isOk        = ($blockSize -eq $RecommendedBlockSize)

                if ($isOk)
                {
                    $status  = 'OK'
                    $message = "Laufwerk ${d}: Blockgroesse $blockSizeKB KB - entspricht Empfehlung ($([Math]::Round($RecommendedBlockSize/1024))KB)."
                    Write-Host "  OK   $message" -ForegroundColor Green
                }
                else
                {
                    $status  = 'Warning'
                    $message = "Laufwerk ${d}: Blockgroesse $blockSizeKB KB - empfohlen sind $([Math]::Round($RecommendedBlockSize/1024)) KB fuer SQL Server."
                    Write-Host "  WARN $message" -ForegroundColor Yellow
                }

                Invoke-sqmLogging -Message $message -FunctionName $functionName -Level $(if ($isOk) { 'INFO' } else { 'WARNING' })

                $results.Add([PSCustomObject]@{
                    Drive                = $d
                    Path                 = "${d}:\"
                    Label                = $vol.Label
                    BlockSize            = $blockSize
                    BlockSizeKB          = $blockSizeKB
                    RecommendedBlockSize = $RecommendedBlockSize
                    IsRecommended        = $isOk
                    Status               = $status
                    Message              = $message
                })
            }
            catch
            {
                $errMsg = "Fehler bei Laufwerk ${d}: $($_.Exception.Message)"
                Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
                if ($EnableException) { throw }
                Write-Error $errMsg

                $results.Add([PSCustomObject]@{
                    Drive                = $d
                    Path                 = "${d}:\"
                    Label                = $null
                    BlockSize            = $null
                    BlockSizeKB          = $null
                    RecommendedBlockSize = $RecommendedBlockSize
                    IsRecommended        = $false
                    Status               = 'Error'
                    Message              = $errMsg
                })
            }
        }

        Invoke-sqmLogging -Message "$functionName abgeschlossen. $($results.Count) Laufwerke geprueft." -FunctionName $functionName -Level 'INFO'
        return $results
    }
}
