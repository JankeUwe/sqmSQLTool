#Requires -Version 5.1
<#
.SYNOPSIS
    Erstellt einen HTML-Hardware-Konfigurationsbericht fuer einen oder mehrere Server.

.DESCRIPTION
    Sammelt Systeminformationen via CIM/WMI und generiert einen detaillierten HTML-Report mit:
    - Betriebssystem (Windows-Version, Build, Laufzeit, Domain)
    - Prozessor (Modell, Sockel, physikalische/logische Kerne, Takt)
    - Arbeitsspeicher (Gesamt, frei, DIMM-Details mit Typ und Geschwindigkeit)
    - Laufwerke (physikalische Datentraeger + logische Laufwerke mit Auslastungsbalken)
    - Netzwerk (IP-Adressen, MAC-Adresse, DNS-Server, Gateway)
    - SQL Server Instanzen (Service-Name, Status, Starttyp)
    - VM-Erkennung (Hyper-V, VMware, VirtualBox, KVM/QEMU, Physisch)

    Voraussetzungen fuer Remote-Abfragen:
    - DCOM/WMI-Zugriff (Port 135 + dynamische Ports) auf dem Zielserver
    - Kein WinRM / PowerShell Remoting erforderlich

.PARAMETER ComputerName
    Zielserver (ein oder mehrere). Standard: lokaler Computer.
    Aliase: SqlInstance, ServerName

.PARAMETER ReportPath
    Ausgabepfad fuer die HTML-Report-Datei(en).
    Standard: %ProgramData%\sqmSQLTool\HardwareReports

.PARAMETER OutputFormat
    Ausgabeformat: HTML (Standard), CSV, TXT oder All (alle Formate gleichzeitig).
    - HTML: Interaktiver Dark-Theme Report (Standard)
    - CSV : Flache CSV-Datei fuer Weiterverarbeitung (Excel, Import etc.)
    - TXT : Lesbare Textdatei (wie CSV aber tabulatorgetrennt)
    - All : HTML + CSV + TXT werden alle erstellt

.PARAMETER NoOpen
    HTML-Datei nach dem Erstellen NICHT automatisch im Browser oeffnen.

.PARAMETER PassThru
    Gibt den vollstaendigen Pfad der erstellten Datei(en) als String zurueck.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen statt Write-Error.

.OUTPUTS
    Kein Output (oder Dateipfad(e) wenn -PassThru angegeben).

.EXAMPLE
    # Lokalen Server analysieren - Report wird automatisch im Browser geoeffnet
    Get-sqmServerHardwareReport

.EXAMPLE
    # Remote-Server
    Get-sqmServerHardwareReport -ComputerName "SQL01"

.EXAMPLE
    # Mehrere Server, eigener Report-Pfad
    Get-sqmServerHardwareReport -ComputerName "SQL01","SQL02","SQL03" -ReportPath "C:\Reports"

.EXAMPLE
    # Nur speichern, nicht oeffnen - Dateipfad zurueckgeben
    $path = Get-sqmServerHardwareReport -ComputerName "SQL01" -NoOpen -PassThru
    Write-Host "Report: $path"

.EXAMPLE
    # CSV-Export fuer Weiterverarbeitung in Excel
    Get-sqmServerHardwareReport -ComputerName "SQL01","SQL02" -OutputFormat CSV -NoOpen

.EXAMPLE
    # Alle Formate auf einmal (HTML + CSV + TXT)
    Get-sqmServerHardwareReport -ComputerName "SQL01" -OutputFormat All -NoOpen -PassThru

.NOTES
    SQL-Instanzen werden ueber Win32_Service ermittelt - kein SQL-Verbindungsaufbau noetig.
    DIMM-Details (Typ, Geschwindigkeit) sind auf manchen VMs nicht verfuegbar (Hypervisor-Abhngigkeit).
    Abhaengigkeiten: Invoke-sqmLogging, Copy-sqmToCentralPath
#>
function Get-sqmServerHardwareReport
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $false, ValueFromPipeline = $true,
                   ValueFromPipelineByPropertyName = $true, Position = 0)]
        [Alias('SqlInstance', 'ServerName')]
        [string[]]$ComputerName = @($env:COMPUTERNAME),

        [Parameter(Mandatory = $false)]
        [string]$ReportPath,

        [Parameter(Mandatory = $false)]
        [ValidateSet('HTML', 'CSV', 'TXT', 'All')]
        [string]$OutputFormat = 'HTML',

        [Parameter(Mandatory = $false)]
        [switch]$NoOpen,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru,

        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name

        if (-not $PSBoundParameters.ContainsKey('ReportPath') -or [string]::IsNullOrWhiteSpace($ReportPath))
        {
            $ReportPath = Join-Path $env:ProgramData 'sqmSQLTool\HardwareReports'
        }

        if (-not (Test-Path $ReportPath))
        {
            $null = New-Item -ItemType Directory -Path $ReportPath -Force
        }

        Invoke-sqmLogging -Message "Starte $functionName" -FunctionName $functionName -Level 'INFO'
    }

    process
    {
        foreach ($computer in $ComputerName)
        {
            if ([string]::IsNullOrWhiteSpace($computer)) { $computer = $env:COMPUTERNAME }

            try
            {
                Write-Host "  [$computer] Sammle Hardware-Daten..." -ForegroundColor Gray

                $hw        = _Get-sqmHardwareData -ComputerName $computer
                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                $datestamp = Get-Date -Format 'yyyyMMdd_HHmm'
                $safeComp  = $computer -replace '[\\/:*?"<>|]', '_'

                $doHtml = ($OutputFormat -eq 'HTML' -or $OutputFormat -eq 'All')
                $doCsv  = ($OutputFormat -eq 'CSV'  -or $OutputFormat -eq 'All')
                $doTxt  = ($OutputFormat -eq 'TXT'  -or $OutputFormat -eq 'All')

                $htmlFile = $null

                # -- HTML --
                if ($doHtml)
                {
                    $html     = _Build-sqmHardwareReportHtml -Data $hw -Timestamp $timestamp
                    $htmlFile = Join-Path $ReportPath "sqmHardwareReport_${safeComp}_${datestamp}.html"
                    $html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
                    Invoke-sqmLogging -Message "Hardware-Report (HTML) gespeichert: $htmlFile" -FunctionName $functionName -Level 'INFO'
                    Write-Host "  [$computer] HTML : $htmlFile" -ForegroundColor Cyan
                    Copy-sqmToCentralPath -Path $htmlFile
                    if ($PassThru) { $htmlFile }
                }

                # -- Flat export-Objekt (gemeinsam fuer CSV + TXT) --
                if ($doCsv -or $doTxt)
                {
                    $flat = _Build-sqmHardwareFlat -Data $hw -Timestamp $timestamp
                }

                # -- CSV --
                if ($doCsv)
                {
                    $csvFile = Join-Path $ReportPath "sqmHardwareReport_${safeComp}_${datestamp}.csv"
                    $flat | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
                    Invoke-sqmLogging -Message "Hardware-Report (CSV) gespeichert: $csvFile" -FunctionName $functionName -Level 'INFO'
                    Write-Host "  [$computer] CSV  : $csvFile" -ForegroundColor Cyan
                    Copy-sqmToCentralPath -Path $csvFile
                    if ($PassThru) { $csvFile }
                }

                # -- TXT --
                if ($doTxt)
                {
                    $txtFile = Join-Path $ReportPath "sqmHardwareReport_${safeComp}_${datestamp}.txt"
                    _Build-sqmHardwareReportTxt -Data $hw -Timestamp $timestamp |
                        Out-File -FilePath $txtFile -Encoding UTF8 -Force
                    Invoke-sqmLogging -Message "Hardware-Report (TXT) gespeichert: $txtFile" -FunctionName $functionName -Level 'INFO'
                    Write-Host "  [$computer] TXT  : $txtFile" -ForegroundColor Cyan
                    Copy-sqmToCentralPath -Path $txtFile
                    if ($PassThru) { $txtFile }
                }

                # Browser oeffnen (nur HTML)
                if ($doHtml -and -not $NoOpen -and $htmlFile)
                {
                    Start-Process $htmlFile
                }
            }
            catch
            {
                $errMsg = "Fehler in $functionName fuer '${computer}': $($_.Exception.Message)"
                Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
                if ($EnableException) { throw }
                Write-Error $errMsg
            }
        }
    }

    end
    {
        Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level 'INFO'
    }
}

# =============================================================================
# Private: Hardware-Daten via CIM sammeln
# =============================================================================
function _Get-sqmHardwareData
{
    param ([string]$ComputerName)

    $isLocal   = ($ComputerName -eq $env:COMPUTERNAME -or
                  $ComputerName -eq '.'              -or
                  $ComputerName -ieq 'localhost')
    $cimParams = if ($isLocal) { @{} } else { @{ ComputerName = $ComputerName } }

    # Wrapper fuer sichere CIM-Abfragen (gibt leeres Array bei Fehler zurueck)
    function _CIM
    {
        param ([string]$Class, [string]$Filter, [string]$Namespace)
        try
        {
            $p = $cimParams.Clone()
            if ($Filter)    { $p['Filter']    = $Filter }
            if ($Namespace) { $p['Namespace'] = $Namespace }
            @(Get-CimInstance -ClassName $Class @p -ErrorAction Stop)
        }
        catch { @() }
    }

    $cs        = _CIM 'Win32_ComputerSystem'                          | Select-Object -First 1
    $os        = _CIM 'Win32_OperatingSystem'                         | Select-Object -First 1
    $procs     = _CIM 'Win32_Processor'
    $phyMem    = _CIM 'Win32_PhysicalMemory'
    $bios      = _CIM 'Win32_BIOS'                                    | Select-Object -First 1
    $logDisks  = _CIM 'Win32_LogicalDisk'    'DriveType=3'
    $physDisks = _CIM 'Win32_DiskDrive'
    $netAdapt  = _CIM 'Win32_NetworkAdapterConfiguration' 'IPEnabled=True'
    $sqlSvcs   = _CIM 'Win32_Service'        "Name LIKE 'MSSQL%'"

    # Optionaler SSD-Check (nur Win8+ / Server 2012+, kann fehlen)
    $physDiskTypes = @{}
    try
    {
        $msftDisks = _CIM 'MSFT_PhysicalDisk' -Namespace 'root/Microsoft/Windows/Storage'
        foreach ($md in $msftDisks)
        {
            # MediaType: 3=HDD, 4=SSD, 5=SCM
            $typeLabel = switch ($md.MediaType) { 3 { 'HDD' } 4 { 'SSD' } 5 { 'SCM' } default { '' } }
            if ($typeLabel -and $md.DeviceId) { $physDiskTypes[$md.DeviceId.Trim()] = $typeLabel }
        }
    }
    catch { }

    # VM-Erkennung
    $isVM   = $false
    $vmType = 'Physisch'
    $model  = if ($cs)   { [string]$cs.Model }               else { '' }
    $mfr    = if ($cs)   { [string]$cs.Manufacturer }         else { '' }
    $biosV  = if ($bios) { [string]$bios.SMBIOSBIOSVersion }  else { '' }

    if    (($model -match 'Virtual Machine' -or $biosV -match 'VRTUAL') -and $mfr -match 'Microsoft')
        { $isVM = $true; $vmType = 'Hyper-V' }
    elseif ($model -match 'VMware'    -or $biosV -match 'VMWARE'  -or $mfr -match 'VMware')
        { $isVM = $true; $vmType = 'VMware' }
    elseif ($model -match 'VirtualBox' -or $biosV -match 'VBOX')
        { $isVM = $true; $vmType = 'VirtualBox' }
    elseif ($mfr   -match 'QEMU'      -or $model  -match 'KVM')
        { $isVM = $true; $vmType = 'KVM/QEMU' }

    [PSCustomObject]@{
        ComputerName    = $ComputerName
        IsVM            = $isVM
        VMType          = $vmType
        ComputerSystem  = $cs
        OS              = $os
        Processors      = $procs
        PhysicalMemory  = $phyMem
        BIOS            = $bios
        LogicalDisks    = $logDisks
        PhysicalDisks   = $physDisks
        PhysicalDiskTypes = $physDiskTypes
        NetworkAdapters = $netAdapt
        SQLServices     = $sqlSvcs
    }
}

# =============================================================================
# Private: HTML-Report aufbauen
# =============================================================================
function _Build-sqmHardwareReportHtml
{
    param (
        [PSCustomObject]$Data,
        [string]$Timestamp
    )

    # --- Hilfsfunktionen ---
    function _H
    {
        param ([string]$t)
        if (-not $t) { return '' }
        $t -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&#39;'
    }

    function _Size
    {
        param ([double]$bytes)
        if ($bytes -le 0)   { return '0 B' }
        if ($bytes -ge 1TB) { return ('{0:N1} TB' -f ($bytes / 1TB)) }
        if ($bytes -ge 1GB) { return ('{0:N1} GB' -f ($bytes / 1GB)) }
        if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
        return ('{0:N0} KB' -f ($bytes / 1KB))
    }

    function _KbSize
    {
        param ([long]$kb)
        _Size ($kb * 1024)
    }

    function _PropRow
    {
        param ([string]$label, [string]$value)
        "<tr><td class='pl'>$(_H $label)</td><td>$(_H $value)</td></tr>"
    }

    function _SecTitle
    {
        param ([string]$title, [string]$icon)
        "<h2 class='stitle'><span class='sicon'>$icon</span>$(_H $title)</h2>"
    }

    $d  = $Data
    $cs = $d.ComputerSystem
    $os = $d.OS

    # --- Zusammenfassungswerte ---
    $totalRamBytes = if ($cs) { [double]$cs.TotalPhysicalMemory } else { 0 }
    $totalRam      = _Size $totalRamBytes
    $freeRamBytes  = if ($os -and $os.FreePhysicalMemory) { [double]$os.FreePhysicalMemory * 1024 } else { 0 }
    $freeRam       = if ($freeRamBytes -gt 0) { _Size $freeRamBytes } else { 'n/a' }
    $ramUsedPct    = if ($totalRamBytes -gt 0) { [int](($totalRamBytes - $freeRamBytes) / $totalRamBytes * 100) } else { 0 }

    $totalCores = 0
    $totalLogic = 0
    foreach ($p in $d.Processors)
    {
        if ($p.NumberOfCores)            { $totalCores += $p.NumberOfCores }
        if ($p.NumberOfLogicalProcessors){ $totalLogic += $p.NumberOfLogicalProcessors }
    }
    $cpuSummary = "$totalCores / $totalLogic"

    $diskCount = ($d.PhysicalDisks | Measure-Object).Count
    $sqlSvcs   = @($d.SQLServices | Where-Object { $_.Name -match '^MSSQLSERVER$|^MSSQL\$' })
    $sqlCount  = $sqlSvcs.Count

    # Uptime berechnen
    $uptimeStr = ''
    if ($os -and $os.LastBootUpTime)
    {
        $span      = (Get-Date) - $os.LastBootUpTime
        $uptimeStr = '{0}d {1}h {2}m' -f [int]$span.TotalDays, $span.Hours, $span.Minutes
    }

    # VM-Badge
    $vmBadge = if ($d.IsVM) {
        "<span class='badge bvm'>$(_H $d.VMType)</span>"
    } else {
        "<span class='badge bhw'>Physisch</span>"
    }

    # -------------------------------------------------------------------------
    # ABSCHNITT: Betriebssystem
    # -------------------------------------------------------------------------
    $osDomain  = if ($cs) { [string]$cs.Domain }       else { 'n/a' }
    $osModel   = if ($cs) { "$($cs.Manufacturer) $($cs.Model)".Trim() } else { 'n/a' }
    $osCaption = if ($os) { [string]$os.Caption }       else { 'n/a' }
    $osBuild   = if ($os) { "Build $($os.BuildNumber)" } else { '' }
    $osVersion = if ($os) { [string]$os.Version }       else { 'n/a' }
    $osLastBoot= if ($os -and $os.LastBootUpTime) { $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm') } else { 'n/a' }

    $osHtml = "<table class='ptbl'><tbody>" +
        (_PropRow 'Betriebssystem'    $osCaption) +
        (_PropRow 'Version / Build'   "$osVersion  $osBuild") +
        (_PropRow 'Hersteller / Modell' $osModel) +
        (_PropRow 'Domain'            $osDomain) +
        (_PropRow 'Letzter Neustart'  $osLastBoot) +
        (_PropRow 'Laufzeit'          $uptimeStr) +
        "</tbody></table>"

    # -------------------------------------------------------------------------
    # ABSCHNITT: Prozessor
    # -------------------------------------------------------------------------
    $cpuHtml = ''
    if ($d.Processors.Count -gt 0)
    {
        $p0 = $d.Processors[0]
        $socketCount = $d.Processors.Count
        $cpuModel    = if ($p0.Name) { $p0.Name.Trim() } else { 'n/a' }
        $cpuSocket   = if ($p0.SocketDesignation) { $p0.SocketDesignation } else { 'n/a' }
        $cpuMHz      = if ($p0.MaxClockSpeed) { "$($p0.MaxClockSpeed) MHz" } else { 'n/a' }
        $cpuGHz      = if ($p0.MaxClockSpeed) { '({0:N2} GHz)' -f ($p0.MaxClockSpeed / 1000) } else { '' }

        $cpuHtml = "<table class='ptbl'><tbody>" +
            (_PropRow 'Modell'              $cpuModel) +
            (_PropRow 'Sockel'              "$socketCount x $cpuSocket") +
            (_PropRow 'Kerne (gesamt)'      "$totalCores ($($p0.NumberOfCores) je Sockel)") +
            (_PropRow 'Logisch (gesamt)'    "$totalLogic ($($p0.NumberOfLogicalProcessors) je Sockel)") +
            (_PropRow 'Max. Takt'           "$cpuMHz $cpuGHz") +
            "</tbody></table>"
    }
    else
    {
        $cpuHtml = '<p class="nodata">Prozessor-Daten nicht verfuegbar.</p>'
    }

    # -------------------------------------------------------------------------
    # ABSCHNITT: Arbeitsspeicher
    # -------------------------------------------------------------------------
    $ramBarColor = if ($ramUsedPct -ge 90) { '#e74c3c' } elseif ($ramUsedPct -ge 75) { '#f39c12' } else { '#27ae60' }
    $ramBar = "<div class='dbar'><div class='dfill' style='width:{0}%;background:{1}'></div></div> <span class='dpct'>{0}% belegt</span>" -f $ramUsedPct, $ramBarColor

    $ramSummaryHtml = "<table class='ptbl'><tbody>" +
        (_PropRow 'Gesamt'              $totalRam) +
        (_PropRow 'Frei'               $freeRam) +
        "<tr><td class='pl'>Auslastung</td><td>$ramBar</td></tr>" +
        (_PropRow 'DIMM-Steckplaetze'  (($d.PhysicalMemory | Measure-Object).Count).ToString()) +
        "</tbody></table>"

    # DIMM-Details
    $dimmHtml = ''
    if ($d.PhysicalMemory -and $d.PhysicalMemory.Count -gt 0)
    {
        $dimmHtml = "<table class='itbl' style='margin-top:10px'><thead><tr>" +
            "<th>Slot</th><th>Kapazitaet</th><th>Geschwindigkeit</th><th>Typ</th>" +
            "</tr></thead><tbody>"

        foreach ($dimm in $d.PhysicalMemory)
        {
            $dimmCap   = if ($dimm.Capacity) { _Size ([double]$dimm.Capacity) } else { 'n/a' }
            $dimmSpeed = if ($dimm.Speed)    { "$($dimm.Speed) MHz" }           else { 'n/a' }
            $dimmType  = switch ([int]$dimm.SMBIOSMemoryType)
            {
                20 { 'DDR' }  21 { 'DDR2' }  22 { 'DDR2 FB' }
                24 { 'DDR3' } 26 { 'DDR4' }  34 { 'DDR5' }
                default { if ($dimm.SMBIOSMemoryType) { "Typ $($dimm.SMBIOSMemoryType)" } else { 'n/a' } }
            }
            $dimmSlot = if ($dimm.DeviceLocator) { $dimm.DeviceLocator } else { 'n/a' }
            $dimmHtml += "<tr><td>$(_H $dimmSlot)</td><td>$(_H $dimmCap)</td><td>$(_H $dimmSpeed)</td><td>$(_H $dimmType)</td></tr>"
        }
        $dimmHtml += '</tbody></table>'
    }
    else
    {
        $dimmHtml = '<p class="nodata">DIMM-Details nicht verfuegbar (VM ohne Speicher-Mapping oder kein WMI-Zugriff).</p>'
    }

    $ramHtml = $ramSummaryHtml + $dimmHtml

    # -------------------------------------------------------------------------
    # ABSCHNITT: Physikalische Datentraeger
    # -------------------------------------------------------------------------
    $physHtml = "<table class='itbl'><thead><tr>" +
        "<th>DiskNr</th><th>Modell</th><th>Groesse</th><th>Typ</th><th>Interface</th><th>SerienNr.</th><th>Partitionen</th>" +
        "</tr></thead><tbody>"

    foreach ($pd in ($d.PhysicalDisks | Sort-Object Index))
    {
        $pdSize    = if ($pd.Size) { _Size ([double]$pd.Size) } else { 'n/a' }
        $pdMedia   = if ($pd.MediaType)    { [string]$pd.MediaType }    else { '' }
        $pdIface   = if ($pd.InterfaceType){ [string]$pd.InterfaceType } else { '' }
        $pdDevId   = if ($pd.DeviceID)     { [string]$pd.DeviceID -replace '^\\\\\.\\PHYSICALDRIVE', '' } else { '' }
        $pdIndex   = if ($pd.Index) { [string]$pd.Index } else { 'n/a' }
        $pdSerial  = if ($pd.SerialNumber) { [string]$pd.SerialNumber } else { 'n/a' }
        # SSD-Info aus MSFT_PhysicalDisk wenn verfuegbar
        $ssdType   = if ($d.PhysicalDiskTypes.ContainsKey($pdDevId)) { $d.PhysicalDiskTypes[$pdDevId] } else { '' }
        $typeDisp  = if ($ssdType) { $ssdType } elseif ($pdMedia -match 'SSD|Solid') { 'SSD' } else { $pdMedia }
        $parts     = if ($pd.Partitions) { [string]$pd.Partitions } else { 'n/a' }

        $physHtml += "<tr><td>$(_H $pdIndex)</td>" +
            "<td>$(_H ([string]$pd.Model))</td>" +
            "<td>$(_H $pdSize)</td>" +
            "<td>$(_H $typeDisp)</td>" +
            "<td>$(_H $pdIface)</td>" +
            "<td>$(_H $pdSerial)</td>" +
            "<td>$(_H $parts)</td></tr>"
    }
    if ($d.PhysicalDisks.Count -eq 0)
    {
        $physHtml += '<tr><td colspan="7" class="norow">Keine physikalischen Datentraeger gefunden</td></tr>'
    }
    $physHtml += '</tbody></table>'

    # -------------------------------------------------------------------------
    # ABSCHNITT: Logische Laufwerke
    # -------------------------------------------------------------------------
    $logHtml = "<table class='itbl'><thead><tr>" +
        "<th>Laufwerk</th><th>Label</th><th>Dateisystem</th>" +
        "<th>Gesamt</th><th>Belegt</th><th>Frei</th><th>Auslastung</th>" +
        "</tr></thead><tbody>"

    foreach ($ld in ($d.LogicalDisks | Sort-Object DeviceID))
    {
        $ldTotal   = if ($ld.Size)      { _Size ([double]$ld.Size) }      else { 'n/a' }
        $ldFree    = if ($ld.FreeSpace) { _Size ([double]$ld.FreeSpace) } else { 'n/a' }
        $ldUsed    = if ($ld.Size -and $ld.FreeSpace) { _Size ([double]($ld.Size - $ld.FreeSpace)) } else { 'n/a' }
        $pctUsed   = if ($ld.Size -gt 0) { [int](([double]($ld.Size - $ld.FreeSpace) / [double]$ld.Size) * 100) } else { 0 }
        $pctFree   = 100 - $pctUsed
        $barColor  = if ($pctFree -lt 10) { '#e74c3c' } elseif ($pctUsed -ge 90) { '#e74c3c' } elseif ($pctUsed -ge 75) { '#f39c12' } else { '#27ae60' }
        $bar       = "<div class='dbar'><div class='dfill' style='width:{0}%;background:{1}'></div></div><span class='dpct'>{0}%</span>" -f $pctUsed, $barColor
        $drive     = if ($ld.DeviceID) { "$($ld.DeviceID)\" } else { 'n/a' }
        $fs        = if ($ld.FileSystem) { [string]$ld.FileSystem } else { 'n/a' }
        $volName   = if ($ld.VolumeName) { [string]$ld.VolumeName } else { '' }
        $warningFlag = if ($pctFree -lt 10) { " ⚠️ KRITISCH" } else { '' }

        $logHtml += "<tr><td><strong>$(_H $drive)</strong></td><td>$(_H $volName)</td><td>$(_H $fs)</td>" +
            "<td>$(_H $ldTotal)</td><td>$(_H $ldUsed)</td><td>$(_H $ldFree)</td><td>$bar$warningFlag</td></tr>"
    }
    if ($d.LogicalDisks.Count -eq 0)
    {
        $logHtml += '<tr><td colspan="7" class="norow">Keine lokalen Laufwerke gefunden</td></tr>'
    }
    $logHtml += '</tbody></table>'

    # -------------------------------------------------------------------------
    # ABSCHNITT: Netzwerk
    # -------------------------------------------------------------------------
    $netHtml = "<table class='itbl'><thead><tr>" +
        "<th>Adapter</th><th>IP-Adresse(n)</th><th>MAC</th><th>DNS-Server</th><th>Gateway</th>" +
        "</tr></thead><tbody>"

    foreach ($na in $d.NetworkAdapters)
    {
        $ips = ''
        if ($na.IPAddress) { $ips = ($na.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) -join ', ' }
        $dns = if ($na.DNSServerSearchOrder) { $na.DNSServerSearchOrder -join ', ' } else { '' }
        $gw  = if ($na.DefaultIPGateway)     { $na.DefaultIPGateway -join ', ' }     else { '' }
        $mac = if ($na.MACAddress)           { [string]$na.MACAddress }              else { '' }
        $adp = if ($na.Description)          { [string]$na.Description }             else { '' }

        $netHtml += "<tr><td>$(_H $adp)</td><td>$(_H $ips)</td><td>$(_H $mac)</td><td>$(_H $dns)</td><td>$(_H $gw)</td></tr>"
    }
    if ($d.NetworkAdapters.Count -eq 0)
    {
        $netHtml += '<tr><td colspan="5" class="norow">Keine Netzwerkadapter mit aktivem IP gefunden</td></tr>'
    }
    $netHtml += '</tbody></table>'

    # -------------------------------------------------------------------------
    # ABSCHNITT: SQL Server Instanzen
    # -------------------------------------------------------------------------
    $sqlHtml = "<table class='itbl'><thead><tr>" +
        "<th>Instanzname</th><th>Service-Name</th><th>Status</th><th>Starttyp</th>" +
        "</tr></thead><tbody>"

    foreach ($svc in ($sqlSvcs | Sort-Object Name))
    {
        $instName = if ($svc.Name -eq 'MSSQLSERVER') { 'Standard-Instanz' } else { [string]$svc.Name -replace '^MSSQL\$', '' }
        $state    = if ($svc.State) { [string]$svc.State } else { 'n/a' }
        $startMode= if ($svc.StartMode) { [string]$svc.StartMode } else { 'n/a' }
        $sc = if ($state -eq 'Running') { '#27ae60' } else { '#e74c3c' }
        $stateBadge = "<span class='badge' style='color:{0};border-color:{0}'>$(_H $state)</span>" -f $sc

        $sqlHtml += "<tr><td><strong>$(_H $instName)</strong></td><td>$(_H ([string]$svc.Name))</td>" +
            "<td>$stateBadge</td><td>$(_H $startMode)</td></tr>"
    }
    if ($sqlSvcs.Count -eq 0)
    {
        $sqlHtml += '<tr><td colspan="4" class="norow">Keine SQL Server-Instanzen gefunden</td></tr>'
    }
    $sqlHtml += '</tbody></table>'

    # -------------------------------------------------------------------------
    # Summary-Karte RAM-Auslastung
    # -------------------------------------------------------------------------
    $ramCardBar = "<div class='cbar'><div class='cfill' style='width:{0}%;background:{1}'></div></div>" -f $ramUsedPct, $ramBarColor

    # =========================================================================
    # HTML zusammenbauen
    # =========================================================================
    return @"
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Hardware Report - $(_H $d.ComputerName)</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: 'Segoe UI', Arial, sans-serif; background: #060f20; color: #e2e8f0; font-size: 13px; }

/* Header */
.hdr { background: linear-gradient(160deg,#060f20 0%,#0b1e3d 100%);
       border-bottom: 2px solid #2e86c1; padding: 28px 32px 20px; }
.hdr h1 { font-size: 24px; font-weight: 600; }
.hdr h1 em { color: #5dade2; font-style: normal; }
.hdr .meta { margin-top: 8px; color: #94a8c0; font-size: 12px;
             display: flex; align-items: center; gap: 20px; flex-wrap: wrap; }

/* Badges */
.badge { display: inline-block; padding: 3px 11px; border-radius: 12px;
         font-size: 11px; font-weight: 700; letter-spacing: 0.04em;
         background: rgba(0,0,0,0.3); border: 1px solid; }
.bvm  { color: #5dade2; border-color: #2e86c1; }
.bhw  { color: #2ecc71; border-color: #27ae60; }

/* Summary Cards */
.cards { display: flex; gap: 16px; padding: 20px 32px; background: #0a1628; flex-wrap: wrap; }
.card { flex: 1; min-width: 130px; border-radius: 8px; padding: 16px 20px;
        background: #0d1f38; border: 1px solid #1e3a5f; }
.card .cnum { font-size: 22px; font-weight: 700; color: #5dade2; white-space: nowrap; }
.card .clbl { font-size: 11px; color: #94a8c0; margin-top: 4px; }
.cbar { width: 100%; height: 5px; background: #1e3a5f; border-radius: 3px; margin-top: 8px; overflow: hidden; }
.cfill { height: 100%; border-radius: 3px; }

/* Content */
.content { padding: 24px 32px; }
.section { margin-bottom: 28px; }
.stitle { font-size: 14px; font-weight: 600; color: #5dade2;
          border-bottom: 1px solid #1e3a5f; padding-bottom: 8px; margin-bottom: 12px;
          display: flex; align-items: center; gap: 8px; }
.sicon { font-size: 15px; }

/* Prop Table */
table.ptbl { width: 100%; border-collapse: collapse; background: #0d1f38;
             border-radius: 6px; overflow: hidden; }
table.ptbl td { padding: 8px 12px; border-bottom: 1px solid #0f2540; vertical-align: middle; }
table.ptbl td.pl { color: #94a8c0; font-size: 12px; width: 210px; white-space: nowrap; }
table.ptbl tr:last-child td { border-bottom: none; }

/* Inner Table */
table.itbl { width: 100%; border-collapse: collapse; background: #0d1f38;
             border-radius: 6px; overflow: hidden; }
table.itbl th { background: #0b1e3d; color: #94a8c0; font-size: 11px; font-weight: 600;
                text-transform: uppercase; letter-spacing: 0.04em;
                padding: 8px 12px; text-align: left; border-bottom: 1px solid #1e3a5f; }
table.itbl td { padding: 8px 12px; border-bottom: 1px solid #0f2540; vertical-align: middle; }
table.itbl tr:last-child td { border-bottom: none; }
table.itbl tr:hover { background: rgba(45,134,193,0.05); }

/* Disk Bar */
.dbar { display: inline-block; width: 80px; height: 8px; background: #1e3a5f;
        border-radius: 4px; overflow: hidden; vertical-align: middle; margin-right: 5px; }
.dfill { height: 100%; border-radius: 4px; }
.dpct { font-size: 11px; color: #94a8c0; vertical-align: middle; }

/* Sub-label */
.sublbl { color: #94a8c0; font-size: 11px; text-transform: uppercase;
          letter-spacing: 0.04em; margin: 12px 0 6px; }

.nodata { color: #94a8c0; font-size: 12px; padding: 10px 2px; font-style: italic; }
.norow { text-align: center; color: #94a8c0; padding: 12px; }

/* Footer */
.footer { padding: 14px 32px; border-top: 1px solid #1e3a5f;
          color: #4a6080; font-size: 11px; }
</style>
</head>
<body>

<div class="hdr">
  <h1>Hardware Report &ndash; <em>$(_H $d.ComputerName)</em></h1>
  <div class="meta">
    <span>Erstellt: $(_H $Timestamp)</span>
    $vmBadge
    $(if ($uptimeStr) { "<span>Laufzeit: $(_H $uptimeStr)</span>" })
  </div>
</div>

<div class="cards">
  <div class="card">
    <div class="cnum">$(_H $totalRam)</div>
    <div class="clbl">Arbeitsspeicher gesamt</div>
    $ramCardBar
  </div>
  <div class="card">
    <div class="cnum">$(_H $cpuSummary)</div>
    <div class="clbl">Kerne / Logisch</div>
  </div>
  <div class="card">
    <div class="cnum">$diskCount</div>
    <div class="clbl">Phys. Datentraeger</div>
  </div>
  <div class="card">
    <div class="cnum">$sqlCount</div>
    <div class="clbl">SQL Server Instanzen</div>
  </div>
</div>

<div class="content">

  <div class="section">
    $(_SecTitle 'Betriebssystem' '&#128421;')
    $osHtml
  </div>

  <div class="section">
    $(_SecTitle 'Prozessor' '&#9881;')
    $cpuHtml
  </div>

  <div class="section">
    $(_SecTitle 'Arbeitsspeicher' '&#128190;')
    $ramHtml
  </div>

  <div class="section">
    $(_SecTitle 'Speicher' '&#128191;')
    <p class="sublbl">Physikalische Datentraeger</p>
    $physHtml
    <p class="sublbl">Logische Laufwerke</p>
    $logHtml
  </div>

  <div class="section">
    $(_SecTitle 'Netzwerk' '&#127760;')
    $netHtml
  </div>

  <div class="section">
    $(_SecTitle 'SQL Server Instanzen' '&#128452;')
    $sqlHtml
  </div>

</div>

<div class="footer">
  sqmSQLTool &nbsp;|&nbsp; dtcSoftware / Uwe Janke &nbsp;|&nbsp; www.powershelldba.de
  &nbsp;&nbsp;&ndash;&nbsp;&nbsp; $(_H $Timestamp)
</div>

</body>
</html>
"@
}

# =============================================================================
# Private: Flaches PSCustomObject fuer CSV/TXT-Export
# =============================================================================
function _Build-sqmHardwareFlat
{
    param (
        [PSCustomObject]$Data,
        [string]$Timestamp
    )

    $d  = $Data
    $cs = $d.ComputerSystem
    $os = $d.OS

    # RAM
    $totalRamBytes = if ($cs) { [double]$cs.TotalPhysicalMemory } else { 0 }
    $totalRamGB    = if ($totalRamBytes -gt 0) { [Math]::Round($totalRamBytes / 1GB, 2) } else { 0 }
    $freeRamBytes  = if ($os -and $os.FreePhysicalMemory) { [double]$os.FreePhysicalMemory * 1024 } else { 0 }
    $freeRamGB     = if ($freeRamBytes -gt 0) { [Math]::Round($freeRamBytes / 1GB, 2) } else { 0 }
    $ramUsedPct    = if ($totalRamBytes -gt 0) { [int](($totalRamBytes - $freeRamBytes) / $totalRamBytes * 100) } else { 0 }

    # CPU
    $totalCores = 0; $totalLogic = 0
    foreach ($p in $d.Processors)
    {
        if ($p.NumberOfCores)             { $totalCores += $p.NumberOfCores }
        if ($p.NumberOfLogicalProcessors) { $totalLogic += $p.NumberOfLogicalProcessors }
    }
    $cpuModel   = if ($d.Processors.Count -gt 0 -and $d.Processors[0].Name) { $d.Processors[0].Name.Trim() } else { '' }
    $cpuSockets = $d.Processors.Count
    $cpuMHz     = if ($d.Processors.Count -gt 0 -and $d.Processors[0].MaxClockSpeed) { $d.Processors[0].MaxClockSpeed } else { 0 }

    # OS
    $osCaption  = if ($os) { [string]$os.Caption }   else { '' }
    $osVersion  = if ($os) { [string]$os.Version }   else { '' }
    $osBuild    = if ($os) { [string]$os.BuildNumber } else { '' }
    $osDomain   = if ($cs) { [string]$cs.Domain }    else { '' }
    $osLastBoot = if ($os -and $os.LastBootUpTime) { $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }

    # Uptime
    $uptimeHours = 0
    if ($os -and $os.LastBootUpTime)
    {
        $uptimeHours = [int]((Get-Date) - $os.LastBootUpTime).TotalHours
    }

    # Disks
    $diskCount    = ($d.PhysicalDisks | Measure-Object).Count
    $totalDiskGB  = [Math]::Round((($d.LogicalDisks | Measure-Object -Property Size -Sum).Sum / 1GB), 2)
    $freeDiskGB   = [Math]::Round((($d.LogicalDisks | Measure-Object -Property FreeSpace -Sum).Sum / 1GB), 2)
    $logDrives    = ($d.LogicalDisks | Sort-Object DeviceID | ForEach-Object { "$($_.DeviceID)\" }) -join '; '

    # SQL
    $sqlInstances = ($d.SQLServices | Where-Object { $_.Name -match '^MSSQLSERVER$|^MSSQL\$' } |
        ForEach-Object { if ($_.Name -eq 'MSSQLSERVER') { 'DEFAULT' } else { $_.Name -replace '^MSSQL\$', '' } }) -join '; '

    # Network (erste aktive IP)
    $firstIP  = ''
    $firstMac = ''
    if ($d.NetworkAdapters.Count -gt 0)
    {
        $na = $d.NetworkAdapters[0]
        $firstIP  = if ($na.IPAddress) { ($na.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1) } else { '' }
        $firstMac = if ($na.MACAddress) { [string]$na.MACAddress } else { '' }
    }

    [PSCustomObject][ordered]@{
        Timestamp       = $Timestamp
        ComputerName    = $d.ComputerName
        VMType          = $d.VMType
        OS              = $osCaption
        OSVersion       = $osVersion
        OSBuild         = $osBuild
        Domain          = $osDomain
        LastBoot        = $osLastBoot
        UptimeHours     = $uptimeHours
        CPUModel        = $cpuModel
        CPUSockets      = $cpuSockets
        CPUCores        = $totalCores
        CPULogical      = $totalLogic
        CPUMHz          = $cpuMHz
        RAMTotalGB      = $totalRamGB
        RAMFreeGB       = $freeRamGB
        RAMUsedPct      = $ramUsedPct
        DimmCount       = ($d.PhysicalMemory | Measure-Object).Count
        PhysicalDisks   = $diskCount
        TotalDiskGB     = $totalDiskGB
        FreeDiskGB      = $freeDiskGB
        LogicalDrives   = $logDrives
        IPAddress       = $firstIP
        MACAddress      = $firstMac
        SQLInstances    = $sqlInstances
    }
}

# =============================================================================
# Private: Lesbare TXT-Ausgabe
# =============================================================================
function _Build-sqmHardwareReportTxt
{
    param (
        [PSCustomObject]$Data,
        [string]$Timestamp
    )

    $flat = _Build-sqmHardwareFlat -Data $Data -Timestamp $Timestamp
    $sep  = '=' * 60

    $lines = @(
        $sep
        "  sqmSQLTool Hardware Report"
        "  $Timestamp"
        $sep
        ''
        "[SYSTEM]"
        "  Computer    : $($flat.ComputerName)"
        "  VM-Typ      : $($flat.VMType)"
        "  Domain      : $($flat.Domain)"
        "  OS          : $($flat.OS)"
        "  Version     : $($flat.OSVersion)  Build $($flat.OSBuild)"
        "  Letzter Boot: $($flat.LastBoot)"
        "  Laufzeit    : $($flat.UptimeHours) Stunden"
        ''
        "[PROZESSOR]"
        "  Modell      : $($flat.CPUModel)"
        "  Sockel      : $($flat.CPUSockets)"
        "  Kerne       : $($flat.CPUCores) physikalisch / $($flat.CPULogical) logisch"
        "  Takt        : $($flat.CPUMHz) MHz"
        ''
        "[ARBEITSSPEICHER]"
        "  Gesamt      : $($flat.RAMTotalGB) GB"
        "  Frei        : $($flat.RAMFreeGB) GB"
        "  Belegt      : $($flat.RAMUsedPct) %"
        "  DIMM-Slots  : $($flat.DimmCount)"
        ''
        "[SPEICHER]"
        "  Phys. Disks : $($flat.PhysicalDisks)"
        "  Gesamt      : $($flat.TotalDiskGB) GB"
        "  Frei        : $($flat.FreeDiskGB) GB"
        "  Laufwerke   : $($flat.LogicalDrives)"
    )

    # Detaillierte Disk-Infos
    if ($Data.PhysicalDisks.Count -gt 0)
    {
        $lines += ""
        $lines += "  [PHYSIKALISCHE DISKS]"
        foreach ($pd in ($Data.PhysicalDisks | Sort-Object Index))
        {
            $pdIndex  = if ($pd.Index) { [string]$pd.Index } else { 'n/a' }
            $pdModel  = if ($pd.Model) { [string]$pd.Model } else { 'n/a' }
            $pdSize   = if ($pd.Size) { '{0:N0}' -f ([double]$pd.Size / 1GB) + ' GB' } else { 'n/a' }
            $pdSerial = if ($pd.SerialNumber) { [string]$pd.SerialNumber } else { 'n/a' }
            $lines += "    Disk $pdIndex : $pdModel ($pdSize, S/N: $pdSerial)"
        }
    }

    # Detaillierte Logical Disk-Infos mit < 10% Warnung
    if ($Data.LogicalDisks.Count -gt 0)
    {
        $lines += ""
        $lines += "  [LOGISCHE LAUFWERKE]"
        foreach ($ld in ($Data.LogicalDisks | Sort-Object DeviceID))
        {
            $drive     = if ($ld.DeviceID) { "$($ld.DeviceID)\" } else { 'n/a' }
            $total     = if ($ld.Size) { '{0:N0}' -f ([double]$ld.Size / 1GB) + ' GB' } else { 'n/a' }
            $free      = if ($ld.FreeSpace) { '{0:N0}' -f ([double]$ld.FreeSpace / 1GB) + ' GB' } else { 'n/a' }
            $pctFree   = if ($ld.Size -gt 0) { [int](([double]$ld.FreeSpace / [double]$ld.Size) * 100) } else { 0 }
            $warning   = if ($pctFree -lt 10) { " [!!! KRITISCH !!!]" } else { '' }
            $lines += "    $drive $total Gesamt, $free Frei ($pctFree% frei)$warning"
        }
    }

    $lines += ''
    $lines += "[NETZWERK]"
    $lines += "  IP-Adresse  : $($flat.IPAddress)"
    $lines += "  MAC         : $($flat.MACAddress)"
    $lines += ''
    $lines += "[SQL SERVER]"
    $lines += "  Instanzen   : $(if ($flat.SQLInstances) { $flat.SQLInstances } else { 'keine' })"
    $lines += ''
    $lines += $sep

    $lines -join "`r`n"
}
