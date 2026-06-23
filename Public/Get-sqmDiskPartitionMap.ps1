<#
.SYNOPSIS
    Zeigt die Zuordnung physischer Datentraeger zu logischen Laufwerksbuchstaben.

.DESCRIPTION
    Ermittelt fuer jeden physischen Datentraeger (Win32_DiskDrive) alle zugeordneten
    logischen Laufwerksbuchstaben via CIM-Assoziationen:

        Win32_DiskDrive
          └─ Win32_DiskDriveToDiskPartition
               └─ Win32_DiskPartition
                    └─ Win32_LogicalDiskToPartition
                         └─ Win32_LogicalDisk  (Laufwerksbuchstabe)

    Ob eine physische Disk "geteilt" ist (mehrere Laufwerksbuchstaben auf einer Disk),
    wird im Property IsShared angezeigt. Das ist besonders relevant, wenn eine Disk
    partitioniert wurde und unterschiedliche Laufwerksbuchstaben auf derselben
    physischen Disk liegen - in diesem Fall sind SerienNummern nicht eindeutig einem
    einzelnen Laufwerk zuzuordnen.

    Unterstuetzt lokale und Remote-Abfragen via CIM (DCOM/WMI, kein WinRM noetig).

.PARAMETER ComputerName
    Zielrechner (ein oder mehrere). Standard: lokaler Computer.
    Aliase: SqlInstance, ServerName

.PARAMETER NoClipboard
    Ergebnis NICHT in die Zwischenablage kopieren.

.OUTPUTS
    PSCustomObject mit folgenden Properties je physischer Disk:
    - ComputerName   : Zielrechner
    - DiskIndex      : Disk-Nummer (0, 1, 2 ...)
    - Model          : Disk-Modell
    - SerialNumber   : Seriennummer der physischen Disk
    - SizeGB         : Gesamtgroesse in GB
    - PartitionCount : Anzahl der Partitionen auf dieser Disk
    - DriveLetters   : Kommagetrennte Liste der Laufwerksbuchstaben (z.B. "C:, D:")
    - IsShared       : True wenn mehr als ein Laufwerksbuchstabe auf dieser Disk liegt
    - MediaType      : Medientyp (HDD, SSD, ...)
    - InterfaceType  : Schnittstellentyp (SCSI, USB, ...)

.EXAMPLE
    Get-sqmDiskPartitionMap

    Zeigt die Partitions-Zuordnung des lokalen Rechners.

.EXAMPLE
    Get-sqmDiskPartitionMap -ComputerName "SQL01"

    Remote-Abfrage gegen SQL01 via CIM/DCOM.

.EXAMPLE
    Get-sqmDiskPartitionMap | Where-Object IsShared | Select-Object DiskIndex, DriveLetters

    Zeigt nur die geteilten Disks (mehrere Laufwerksbuchstaben).

.EXAMPLE
    "SQL01","SQL02" | Get-sqmDiskPartitionMap

    Partitions-Map mehrerer Server per Pipeline.

.NOTES
    Author:       sqmSQLTool
    Prerequisites: CIM-Zugriff (DCOM/WMI), keine PowerShell Remoting erforderlich
    Clipboard:    Ergebnis wird als Tabelle in die Zwischenablage kopiert (je Computer)
#>
function Get-sqmDiskPartitionMap
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false, ValueFromPipeline = $true,
                   ValueFromPipelineByPropertyName = $true, Position = 0)]
        [Alias('SqlInstance', 'ServerName')]
        [string[]]$ComputerName = @($env:COMPUTERNAME),

        [Parameter(Mandatory = $false)]
        [switch]$NoClipboard
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name
        $allResults   = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    process
    {
        foreach ($computer in $ComputerName)
        {
            if ([string]::IsNullOrWhiteSpace($computer)) { $computer = $env:COMPUTERNAME }

            $isLocal   = ($computer -eq $env:COMPUTERNAME -or
                          $computer -eq '.'              -or
                          $computer -ieq 'localhost')
            $cimParams = if ($isLocal) { @{} } else { @{ ComputerName = $computer } }

            Invoke-sqmLogging -Message "[$computer] Ermittle Disk-Partitions-Map..." -FunctionName $functionName -Level 'INFO'

            try
            {
                $physDisks  = @(Get-CimInstance -ClassName Win32_DiskDrive @cimParams -ErrorAction Stop)
                $disk2Part  = @(Get-CimInstance -ClassName Win32_DiskDriveToDiskPartition @cimParams -ErrorAction Stop)
                $part2Log   = @(Get-CimInstance -ClassName Win32_LogicalDiskToPartition @cimParams -ErrorAction Stop)

                # Lookup: Partition DeviceID → Laufwerksbuchstaben
                $partToLetters = @{}
                foreach ($assoc in $part2Log)
                {
                    $partId = $assoc.Antecedent.DeviceID
                    $letter = $assoc.Dependent.DeviceID
                    if (-not $partToLetters.ContainsKey($partId))
                    {
                        $partToLetters[$partId] = [System.Collections.Generic.List[string]]::new()
                    }
                    $partToLetters[$partId].Add($letter)
                }

                # Lookup: Disk DeviceID → Laufwerksbuchstaben (ueber Partition-Zwischenschicht)
                $diskToLetters = @{}
                foreach ($assoc in $disk2Part)
                {
                    $diskId = $assoc.Antecedent.DeviceID
                    $partId = $assoc.Dependent.DeviceID
                    if (-not $diskToLetters.ContainsKey($diskId))
                    {
                        $diskToLetters[$diskId] = [System.Collections.Generic.List[string]]::new()
                    }
                    if ($partToLetters.ContainsKey($partId))
                    {
                        foreach ($letter in $partToLetters[$partId])
                        {
                            $diskToLetters[$diskId].Add($letter)
                        }
                    }
                }

                $computerResults = [System.Collections.Generic.List[PSCustomObject]]::new()

                foreach ($disk in ($physDisks | Sort-Object Index))
                {
                    $diskId   = $disk.DeviceID
                    $letters  = if ($diskToLetters.ContainsKey($diskId)) {
                        @($diskToLetters[$diskId] | Sort-Object)
                    } else { @() }

                    $sizeGB      = if ($disk.Size) { [math]::Round([double]$disk.Size / 1GB, 2) } else { 0 }
                    $serial      = if (-not [string]::IsNullOrWhiteSpace($disk.SerialNumber)) { $disk.SerialNumber.Trim() } else { 'N/A' }
                    $model       = if (-not [string]::IsNullOrWhiteSpace($disk.Model))        { $disk.Model.Trim() }        else { 'N/A' }
                    $partCount   = if ($disk.Partitions) { [int]$disk.Partitions } else { 0 }
                    $isShared    = $letters.Count -gt 1
                    $letterStr   = if ($letters.Count -gt 0) { $letters -join ', ' } else { '(keine)' }
                    $diskIndex   = if ($null -ne $disk.Index) { [int]$disk.Index } else { -1 }

                    $obj = [PSCustomObject]@{
                        ComputerName   = $computer
                        DiskIndex      = $diskIndex
                        Model          = $model
                        SerialNumber   = $serial
                        SizeGB         = $sizeGB
                        PartitionCount = $partCount
                        DriveLetters   = $letterStr
                        IsShared       = $isShared
                        MediaType      = if ($disk.MediaType)    { [string]$disk.MediaType }    else { '' }
                        InterfaceType  = if ($disk.InterfaceType){ [string]$disk.InterfaceType } else { '' }
                    }

                    $tag = if ($isShared) { ' [GETEILT]' } else { '' }
                    Invoke-sqmLogging -Message "[$computer] Disk $diskIndex : $model | $sizeGB GB | $partCount Partitionen | Laufwerke: $letterStr$tag" `
                        -FunctionName $functionName -Level 'INFO'

                    $computerResults.Add($obj)
                    $allResults.Add($obj)
                    $obj
                }

                if (-not $NoClipboard -and $computerResults.Count -gt 0)
                {
                    try
                    {
                        $clipText = $computerResults | Format-Table -AutoSize | Out-String
                        Set-Clipboard -Value $clipText.Trim()
                        Invoke-sqmLogging -Message "[$computer] Ergebnis in Zwischenablage kopiert." -FunctionName $functionName -Level 'INFO'
                    }
                    catch
                    {
                        Invoke-sqmLogging -Message "[$computer] Zwischenablage konnte nicht beschrieben werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
                    }
                }
            }
            catch
            {
                Invoke-sqmLogging -Message "[$computer] Fehler: $($_.Exception.Message)" -FunctionName $functionName -Level 'ERROR'
                Write-Error "Fehler beim Ermitteln der Partitions-Map fuer '$computer': $($_.Exception.Message)"
            }
        }
    }

    end { }
}
