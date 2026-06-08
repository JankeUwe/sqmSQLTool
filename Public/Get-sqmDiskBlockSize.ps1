<#
.SYNOPSIS
    Prueft die NTFS-Blockgroesse (Cluster-Groesse) von Laufwerken auf 64KB.

.DESCRIPTION
    Liest die NTFS-Allokationseinheit (Blockgroesse) der angegebenen Laufwerke
    per WMI (Win32_Volume) und prueft ob die fuer SQL Server empfohlenen
    64 KB (65536 Bytes) konfiguriert sind.

    Kann entweder gezielt einzelne Laufwerkbuchstaben pruefen oder automatisch
    alle Laufwerke ermitteln die von einer SQL Server-Instanz genutzt werden
    (Data, Log, Backup, TempDB).

    Rein lesender Zugriff - keine Aenderungen am System.
    Zum Formatieren: Invoke-sqmFormatDrive64k

.PARAMETER Drive
    Laufwerkbuchstabe(n) ohne Doppelpunkt, z.B. 'F', 'G', 'H'.
    Pipeline-faehig. Wenn nicht angegeben: -SqlInstance muss gesetzt sein.

.PARAMETER SqlInstance
    SQL Server-Instanz. Wenn angegeben werden automatisch alle von SQL Server
    genutzten Laufwerke (Data, Log, Backup, TempDB) aus der Registry ermittelt.

.PARAMETER ComputerName
    Zielcomputer fuer die WMI-Abfrage. Standard: lokaler Computer.

.PARAMETER RecommendedBlockSize
    Empfohlene Blockgroesse in Bytes. Standard: 65536 (64 KB).

.PARAMETER EnableException
    Ausnahmen sofort ausloesen statt Write-Error.

.OUTPUTS
    [PSCustomObject] je Laufwerk mit den Feldern:
        Drive                : Laufwerkbuchstabe
        Path                 : Vollstaendiger Pfad (z.B. F:\)
        Label                : Volume-Label
        BlockSize            : Aktuelle Blockgroesse in Bytes
        BlockSizeKB          : Aktuelle Blockgroesse in KB
        RecommendedBlockSize : Empfohlene Blockgroesse in Bytes
        IsRecommended        : $true wenn Blockgroesse korrekt
        Status               : OK | Warning | NotNTFS | Error
        Message              : Detailmeldung

.EXAMPLE
    # Einzelne Laufwerke pruefen
    Get-sqmDiskBlockSize -Drive 'F', 'G', 'H'

.EXAMPLE
    # Automatisch alle SQL-Laufwerke der Instanz ermitteln und pruefen
    Get-sqmDiskBlockSize -SqlInstance "SQL01"

.EXAMPLE
    # Pipeline
    'F','G' | Get-sqmDiskBlockSize

.EXAMPLE
    # Nur Laufwerke mit falscher Blockgroesse anzeigen
    Get-sqmDiskBlockSize -SqlInstance "SQL01" | Where-Object { -not $_.IsRecommended }

.NOTES
    SQL Server Empfehlung: NTFS-Allokationseinheit 64 KB fuer alle Datenlaufwerke.
    Standard-Windows-Format: 4 KB - fuer SQL Server nicht optimal.
    Gilt nicht fuer System- und OS-Laufwerke (C:\).
    Zum Formatieren mit 64 KB: Invoke-sqmFormatDrive64k
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
