# ---------------------------------------------------------------------------
# Private Hilfsfunktionen fuer Invoke-sqmSplunkConfiguration
# Script-Scope, nicht exportiert (kein -sqm im Namen)
# ---------------------------------------------------------------------------

# Schreibt Nachricht in Logdatei und Konsole (lokale Verwendung in LocalCore)
function _sqmSplunkWriteLog {
    param([string]$LogFile, [string]$Msg)
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Msg"
    Add-Content -Path $LogFile -Value $entry -Encoding UTF8
    Write-Host $entry
}

# Gibt Nachricht an GUI-Callback und/oder Logdatei aus (aeussere Funktionen).
# Schreibt IMMER in die Logdatei, wenn eine angegeben ist - Protokollierung ist
# Standardverhalten, kein Opt-in.
function _sqmSplunkGuiLog {
    param([string]$Message, [ScriptBlock]$LogCallback, [string]$LogFile)
    if ($LogFile) { _sqmSplunkWriteLog $LogFile $Message }
    else          { Write-Host $Message }
    if ($LogCallback) { & $LogCallback $Message }
}

# Lokale Kernlogik: SQL-Instanzen ermitteln, Env-Vars setzen, Dienst verwalten.
# Wird als String serialisiert und via Invoke-Command remote ausgefuehrt.
# Darf KEINE externen Abhaengigkeiten haben.
# Verwendet _sqmSplunkWriteLog - wird zusammen mit dieser Funktion serialisiert.
function _sqmSplunk_LocalCore {
    param([string]$LogFile, [string]$Mode)

    $ErrorActionPreference = 'Continue'

    $logFile = $LogFile
    $logDir  = Split-Path -Parent $logFile
    if ($logDir -and -not (Test-Path $logDir)) {
        $null = New-Item -ItemType Directory -Path $logDir -Force
    }

    _sqmSplunkWriteLog $logFile "=== Invoke-sqmSplunkConfiguration | Modus: $Mode | $(hostname) ==="
    _sqmSplunkWriteLog $logFile "Logdatei: $logFile"

    if ($Mode -ne 'Test') {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            $msg = 'FEHLER: Administratorrechte erforderlich. PowerShell als Administrator starten und erneut ausfuehren.'
            _sqmSplunkWriteLog $logFile $msg
            Write-Warning $msg
            return $false
        }
    }

    # Remove-Modus ist eine vollstaendige Rueckbau-Aktion (Env-Vars weg, Dienst gestoppt) und
    # setzt bewusst KEINE vorhandene SQL-Instanz voraus - sie kann beim Ausbau/Deinstallieren
    # der Instanz bereits entfernt worden sein. Deshalb eigener, fruehzeitiger Zweig ohne die
    # Instanz-Erkennung weiter unten.
    if ($Mode -eq 'Remove') {
        $existingVars = foreach ($varName in ([Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Machine)).Keys) {
            if ($varName -match '^MSSQL\d+_Log$') { $varName }
        }

        if ($existingVars.Count -eq 0) {
            _sqmSplunkWriteLog $logFile 'Keine MSSQLn_Log-Umgebungsvariablen vorhanden.'
        } else {
            foreach ($varName in $existingVars) {
                [Environment]::SetEnvironmentVariable($varName, $null, [EnvironmentVariableTarget]::Machine)
                _sqmSplunkWriteLog $logFile "  Umgebungsvariable '$varName' entfernt."
            }
        }

        $svcName = 'SplunkForwarder'
        $svc     = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svc) {
            _sqmSplunkWriteLog $logFile "WARN: Dienst '$svcName' nicht vorhanden."
        } elseif ($svc.Status -eq 'Stopped') {
            _sqmSplunkWriteLog $logFile "Dienst '$svcName' war bereits gestoppt."
        } else {
            try {
                # -ErrorAction Stop ist noetig, damit ein fehlgeschlagener Stop hier landet statt
                # (bei $ErrorActionPreference = 'Continue') stillschweigend als Erfolg durchzulaufen.
                Stop-Service -Name $svcName -Force -ErrorAction Stop
                _sqmSplunkWriteLog $logFile "Dienst '$svcName' gestoppt."
            } catch {
                _sqmSplunkWriteLog $logFile "FEHLER beim Stoppen: $_"
            }
        }

        _sqmSplunkWriteLog $logFile '=== Invoke-sqmSplunkConfiguration Ende ==='
        return $true
    }

    $instKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (-not (Test-Path $instKey)) {
        _sqmSplunkWriteLog $logFile 'Keine SQL Server-Instanzen gefunden.'
        return $true
    }

    $instances     = Get-ItemProperty -Path $instKey
    $instanceNames = $instances.PSObject.Properties |
                     Where-Object { $_.Name -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider') } |
                     Select-Object -ExpandProperty Name

    if ($instanceNames.Count -eq 0) {
        _sqmSplunkWriteLog $logFile 'Keine Instanzen in der Registry eingetragen.'
        return $true
    }

    _sqmSplunkWriteLog $logFile "Instanzen gefunden: $($instanceNames.Count) ($($instanceNames -join ', '))"

    # Deterministische Reihenfolge, damit MSSQL1_Log/MSSQL2_Log/... bei unveraendertem
    # Instanzbestand stabil denselben Instanzen zugeordnet bleiben (Registry-Enumerationsreihenfolge
    # ist nicht garantiert).
    $instanceNames = $instanceNames | Sort-Object

    function _sqmSplunk_ResolveLogDir {
        param([string]$InstName, [string]$InstID)

        $logDir = $null
        try {
            $asm = [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.Smo')
            if ($asm) {
                $srvName = if ($InstName -eq 'MSSQLSERVER') { '(local)' } else { "(local)\$InstName" }
                $srv     = New-Object Microsoft.SqlServer.Management.Smo.Server($srvName)
                $logDir  = $srv.ErrorLogPath
            }
        } catch { }

        if (-not $logDir) {
            $regP = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$InstID\MSSQLServer\Parameters"
            if (Test-Path $regP) {
                $prm = Get-ItemProperty -Path $regP
                $arg = ($prm.PSObject.Properties |
                        Where-Object { $_.Name -like 'SQLArg*' -and $_.Value -like '-e*' }).Value
                if ($arg) {
                    $logDir = Split-Path ($arg -replace '^-e"?','' -replace '"$','')
                }
            }
        }

        return $logDir
    }

    $i = 1
    foreach ($instName in $instanceNames) {
        $instID  = $instances.$instName
        $varName = "MSSQL${i}_Log"

        # Ein gesetzter Pfad, der nicht mehr existiert, ist veraltet - typischerweise weil eine neue
        # SQL-Version installiert wurde und das alte ErrorLog-Verzeichnis (z.B. MSSQL15.MSSQLSERVER)
        # dabei entfernt/ersetzt wurde. Solche Variablen wuerden Splunk dauerhaft auf einen toten Pfad
        # zeigen lassen und Fehlalarme ausloesen - sie muessen aktualisiert werden, auch wenn sie
        # bereits gesetzt sind.
        $existing = [Environment]::GetEnvironmentVariable($varName, [EnvironmentVariableTarget]::Machine)
        $stale    = ($null -ne $existing) -and (-not (Test-Path -LiteralPath $existing))

        if ($Mode -eq 'Test') {
            if ($null -eq $existing) {
                _sqmSplunkWriteLog $logFile "TEST: '$varName' nicht gesetzt."
            } elseif ($stale) {
                _sqmSplunkWriteLog $logFile "TEST: '$varName' = '$existing' - Pfad existiert nicht mehr (veraltet, z.B. nach SQL-Versionswechsel)."
            } else {
                _sqmSplunkWriteLog $logFile "TEST: '$varName' = '$existing'"
            }
            $i++
            continue
        }

        _sqmSplunkWriteLog $logFile "Verarbeite Instanz $i : $instName (ID: $instID)"

        if ($null -ne $existing -and -not $stale) {
            _sqmSplunkWriteLog $logFile "  '$varName' bereits gesetzt ('$existing') - wird nicht ueberschrieben."
            $i++
            continue
        }
        if ($stale) {
            _sqmSplunkWriteLog $logFile "  '$varName' zeigt auf nicht mehr vorhandenen Pfad ('$existing') - wird aktualisiert."
        }

        try {
            $logDir = _sqmSplunk_ResolveLogDir -InstName $instName -InstID $instID
            if (-not $logDir) { throw 'Pfad nicht ermittelbar.' }

            _sqmSplunkWriteLog $logFile "  ErrorLog-Pfad: $logDir"
            [Environment]::SetEnvironmentVariable($varName, $logDir, [EnvironmentVariableTarget]::Machine)
            _sqmSplunkWriteLog $logFile "  OK: '$varName' = '$logDir' gesetzt."
        } catch {
            _sqmSplunkWriteLog $logFile "  FEHLER bei $instName : $_"
        }

        $i++
    }

    # Verwaiste MSSQLn_Log-Variablen (n > aktuelle Instanzanzahl) entfernen, z.B. wenn eine Instanz
    # bei einem Versionswechsel komplett deinstalliert statt in-place aktualisiert wurde. Ohne diese
    # Bereinigung ueberwacht Splunk weiterhin einen Pfad, der zu keiner vorhandenen Instanz mehr gehoert.
    $orphaned = foreach ($varName in ([Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Machine)).Keys) {
        if ($varName -match '^MSSQL(\d+)_Log$' -and [int]$Matches[1] -gt $instanceNames.Count) {
            $varName
        }
    }

    foreach ($varName in $orphaned) {
        if ($Mode -eq 'Test') {
            _sqmSplunkWriteLog $logFile "TEST: '$varName' ist verwaist (keine passende Instanz mehr) - wuerde entfernt."
        } else {
            [Environment]::SetEnvironmentVariable($varName, $null, [EnvironmentVariableTarget]::Machine)
            _sqmSplunkWriteLog $logFile "  Verwaiste Variable '$varName' entfernt."
        }
    }

    $svcName = 'SplunkForwarder'
    $svc     = Get-Service -Name $svcName -ErrorAction SilentlyContinue

    if (-not $svc) {
        _sqmSplunkWriteLog $logFile "WARN: Dienst '$svcName' nicht vorhanden."
    } elseif ($Mode -eq 'Test') {
        _sqmSplunkWriteLog $logFile "TEST: Dienst '$svcName' Status = $($svc.Status)"
        if ($svc.Status -ne 'Running') {
            try {
                Start-Service -Name $svcName -ErrorAction Stop
                _sqmSplunkWriteLog $logFile 'TEST: Dienst gestartet.'
            } catch {
                _sqmSplunkWriteLog $logFile "TEST: FEHLER beim Starten: $_"
            }
        }
    } else {
        if ($svc.Status -eq 'Running') {
            try {
                # -ErrorAction Stop ist noetig, damit ein fehlgeschlagener Stop-Schritt hier landet
                # statt (bei $ErrorActionPreference = 'Continue') stillschweigend als Erfolg durchzulaufen.
                Restart-Service -Name $svcName -Force -ErrorAction Stop
                _sqmSplunkWriteLog $logFile "Dienst '$svcName' neu gestartet."
            } catch {
                _sqmSplunkWriteLog $logFile "FEHLER beim Neustart: $_"

                # Restart-Service kann den Dienst bereits gestoppt haben, bevor der Fehler auftrat -
                # ohne Nachstart-Versuch bliebe er dann stehen, obwohl er vorher lief.
                $afterRestart = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                if ($afterRestart -and $afterRestart.Status -ne 'Running') {
                    try {
                        Start-Service -Name $svcName -ErrorAction Stop
                        _sqmSplunkWriteLog $logFile "  '$svcName' nach fehlgeschlagenem Neustart erfolgreich gestartet."
                    } catch {
                        _sqmSplunkWriteLog $logFile "  FEHLER: '$svcName' konnte nach fehlgeschlagenem Neustart nicht gestartet werden: $_"
                    }
                }
            }
        } else {
            try {
                Start-Service -Name $svcName -ErrorAction Stop
                _sqmSplunkWriteLog $logFile "Dienst '$svcName' gestartet."
            } catch {
                _sqmSplunkWriteLog $logFile "WARN: '$svcName' nicht laufend - Start fehlgeschlagen: $_"
            }
        }
    }

    _sqmSplunkWriteLog $logFile '=== Invoke-sqmSplunkConfiguration Ende ==='
    return $true
}

# Remote-Engine: fuehrt _sqmSplunk_LocalCore auf mehreren Rechnern aus
function _sqmSplunk_OnComputers {
    param(
        [string[]]$ComputerNames,
        [string]$Mode,
        [string]$LogPath,
        [string]$LogFile,
        [System.Management.Automation.PSCredential]$Credential,
        [ScriptBlock]$LogCallback
    )

    if ($ComputerNames.Count -eq 0) {
        _sqmSplunkGuiLog 'Keine Computer angegeben.' $LogCallback $LogFile
        return
    }

    _sqmSplunkGuiLog "$($ComputerNames.Count) Computer werden verarbeitet..." $LogCallback $LogFile

    # Beide Funktionen serialisieren - _sqmSplunk_LocalCore benoetigt _sqmSplunkWriteLog remote
    $coreStr    = ${function:_sqmSplunk_LocalCore}.ToString()
    $writeStr   = ${function:_sqmSplunkWriteLog}.ToString()
    $combined   = "function _sqmSplunkWriteLog {$writeStr} ; function _sqmSplunk_LocalCore {$coreStr}"

    # Jeder Zielrechner schreibt sein eigenes lokales Log unter $LogPath (auf sich selbst) -
    # unabhaengig vom Controller-Log ($LogFile), das die Orchestrierung hier dokumentiert.
    $remoteBlock = {
        param([string]$LogPath, [string]$Mode, [string]$Combined)
        . ([ScriptBlock]::Create($Combined))
        if (-not (Test-Path $LogPath)) { $null = New-Item -ItemType Directory -Path $LogPath -Force }
        $rLogFile = Join-Path $LogPath ("SplunkConfig_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        _sqmSplunk_LocalCore -LogFile $rLogFile -Mode $Mode
    }

    $splat = @{
        ScriptBlock  = $remoteBlock
        ArgumentList = @($LogPath, $Mode, $combined)
        ErrorAction  = 'Continue'
    }
    if ($Credential) { $splat['Credential'] = $Credential }

    $results = @()

    foreach ($name in $ComputerNames) {
        $name = $name.Trim()
        if (-not $name) { continue }

        _sqmSplunkGuiLog "Verbinde zu $name ..." $LogCallback $LogFile
        $entry = [PSCustomObject]@{ Computer = $name; Status = ''; Fehler = '' }

        if (-not (Test-Connection -ComputerName $name -Count 1 -Quiet)) {
            Write-Warning "$name nicht erreichbar - wird uebersprungen."
            $entry.Status = 'Nicht erreichbar'
            $results += $entry
            continue
        }

        try {
            # In eine Variable fangen statt frei durchlaufen zu lassen - sonst wuerde der
            # Rueckgabewert von _sqmSplunk_LocalCore (seit Remove-Modus $true/$false) unterhalb
            # in $results einsickern und die Zusammenfassung verfaelschen.
            $coreResult = Invoke-Command -ComputerName $name @splat
            if ($coreResult -eq $false) {
                # LocalCore ist frueh abgebrochen (z.B. fehlende Administratorrechte auf dem
                # Zielrechner) - ohne diese Pruefung wuerde das hier faelschlich als Erfolg gelten,
                # obwohl auf dem Zielrechner nichts geaendert wurde.
                Write-Warning "$name - LocalCore vorzeitig abgebrochen (siehe lokales Log auf dem Zielrechner)."
                $entry.Status = 'Fehler (siehe Zielrechner-Log)'
            } else {
                $entry.Status = 'Erfolgreich'
                _sqmSplunkGuiLog "  $name - OK" $LogCallback $LogFile
            }
        } catch {
            Write-Warning "Fehler bei $name : $_"
            $entry.Status = 'Fehler'
            $entry.Fehler = $_.Exception.Message
        }
        $results += $entry
    }

    _sqmSplunkGuiLog '' $LogCallback $LogFile
    _sqmSplunkGuiLog '=== Zusammenfassung ===' $LogCallback $LogFile
    $tableText = $results | Format-Table -AutoSize | Out-String
    Write-Host $tableText
    if ($LogFile) { Add-Content -Path $LogFile -Value $tableText -Encoding UTF8 }
    return $results
}

# AD-OU-Modus
function _sqmSplunk_ForOU {
    param(
        [string]$SearchOU,
        [string]$Mode,
        [string]$LogPath,
        [string]$LogFile,
        [System.Management.Automation.PSCredential]$Credential,
        [ScriptBlock]$LogCallback
    )

    Install-sqmAdModule

    $domainDN   = (Get-ADDomain).DistinguishedName
    $searchBase = if ($SearchOU -match '^OU=') { $SearchOU } else { "OU=$SearchOU,$domainDN" }

    _sqmSplunkGuiLog "AD-Suche unter: $searchBase" $LogCallback $LogFile

    $adSplat = @{ Filter = '*'; SearchBase = $searchBase; Properties = 'OperatingSystem' }
    if ($Credential) { $adSplat['Credential'] = $Credential }

    $computers = Get-ADComputer @adSplat | Where-Object { $_.OperatingSystem -match 'Server' }

    if ($computers.Count -eq 0) {
        _sqmSplunkGuiLog "Keine Server in der OU '$SearchOU' gefunden." $LogCallback $LogFile
        return
    }

    $names = $computers | Select-Object -ExpandProperty Name
    _sqmSplunkGuiLog "$($names.Count) Server in der OU gefunden." $LogCallback $LogFile

    _sqmSplunk_OnComputers -ComputerNames $names -Mode $Mode -LogPath $LogPath -LogFile $LogFile `
                           -Credential $Credential -LogCallback $LogCallback
}

# Explizite Computerliste (Array oder Textdatei)
function _sqmSplunk_ForList {
    param(
        [string[]]$ComputerList,
        [string]$Mode,
        [string]$LogPath,
        [string]$LogFile,
        [System.Management.Automation.PSCredential]$Credential,
        [ScriptBlock]$LogCallback
    )

    $resolved = @()

    foreach ($entry in $ComputerList) {
        $entry = $entry.Trim()
        if (-not $entry) { continue }

        if (Test-Path -LiteralPath $entry -PathType Leaf) {
            _sqmSplunkGuiLog "Lese Computernamen aus Datei: $entry" $LogCallback $LogFile
            $lines = Get-Content -LiteralPath $entry -Encoding UTF8 |
                     Where-Object { $_ -and $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') }
            foreach ($line in $lines) {
                $n = $line.Trim()
                if ($n) { $resolved += $n }
            }
        } else {
            $resolved += $entry
        }
    }

    if ($resolved.Count -eq 0) {
        _sqmSplunkGuiLog 'Keine Computernamen in der Liste gefunden.' $LogCallback $LogFile
        return
    }

    $unique = $resolved | Select-Object -Unique
    _sqmSplunkGuiLog "$($unique.Count) eindeutige Computer." $LogCallback $LogFile

    _sqmSplunk_OnComputers -ComputerNames $unique -Mode $Mode -LogPath $LogPath -LogFile $LogFile `
                           -Credential $Credential -LogCallback $LogCallback
}


# ---------------------------------------------------------------------------
# Oeffentliche Funktion
# ---------------------------------------------------------------------------

function Invoke-sqmSplunkConfiguration {
    <#
    .SYNOPSIS
        Configures the Splunk Universal Forwarder on SQL Server hosts.
    .DESCRIPTION
        Detects all SQL Server instances, sets machine-wide environment variables
        for the ErrorLog path (MSSQL1_Log, MSSQL2_Log, ...) and manages the
        SplunkForwarder service — locally or remotely on any number of servers.
        Existing, still-valid environment variables are not overwritten. Variables whose path no
        longer exists (e.g. after installing a new SQL Server version) are corrected automatically,
        and variables left over from an instance that no longer exists are removed - both would
        otherwise leave Splunk monitoring a stale path and raising false alerts.
        Mode Remove tears the configuration back down: all MSSQLn_Log environment variables are
        removed and SplunkForwarder is stopped, regardless of which SQL instances are currently
        installed.
    .PARAMETER Mode
        Set    - Set environment variables and start/restart SplunkForwarder (default).
        Test   - Check only, no changes.
        Remove - Remove all MSSQLn_Log environment variables and stop SplunkForwarder.
    .PARAMETER Remote
        Remote execution via AD OU search. Combine with -SearchOU.
    .PARAMETER SearchOU
        Distinguished Name or simple OU name. Default: OUServDatabase.
    .PARAMETER ComputerList
        Explicit server list: string array or path to a text file (# = comment).
    .PARAMETER Credential
        Credentials for AD and remoting.
    .PARAMETER LogPath
        Directory for log files. Default: sqmSQLTool LogPath configuration.
    .PARAMETER LogCallback
        Optional ScriptBlock for GUI logging.
    .EXAMPLE
        Invoke-sqmSplunkConfiguration
    .EXAMPLE
        Invoke-sqmSplunkConfiguration -Mode Test
    .EXAMPLE
        Invoke-sqmSplunkConfiguration -Remote -SearchOU "OU=DB-Server,DC=contoso,DC=com"
    .EXAMPLE
        Invoke-sqmSplunkConfiguration -ComputerList "SRV-SQL01","SRV-SQL02"
    .EXAMPLE
        Invoke-sqmSplunkConfiguration -ComputerList "C:\Listen\db-server.txt" -Mode Test
    .EXAMPLE
        Invoke-sqmSplunkConfiguration -Mode Remove
    .NOTES
        Set and Remove modes require local administrator rights.
        Remote: WinRM must be active on target servers.
        AD OU mode: ActiveDirectory module is automatically installed if needed.
        A log file is always written under -LogPath - this is standard behavior, not opt-in.
        In Remote/List mode this covers the controller-side orchestration (AD search, per-host
        connection attempts, summary); each target server additionally writes its own local log.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Set', 'Test', 'Remove')]
        [string]$Mode = 'Set',

        [switch]$Remote,

        [string]$SearchOU = 'OUServDatabase',

        [string[]]$ComputerList,

        [System.Management.Automation.PSCredential]$Credential,

        [string]$LogPath,

        [ScriptBlock]$LogCallback
    )

    if (-not $LogPath) {
        $LogPath = Get-sqmConfig -Key 'LogPath'
        if (-not $LogPath) { $LogPath = Join-Path $env:ProgramData 'sqmSQLTool\Logs' }
    }

    # Ein Log pro Aufruf ist Standardverhalten - unabhaengig vom gewaehlten Modus (Local/Remote/List)
    # und ohne dass der Aufrufer dafuer etwas angeben muss.
    if (-not (Test-Path $LogPath)) { $null = New-Item -ItemType Directory -Path $LogPath -Force }
    $LogFile = Join-Path $LogPath ("SplunkConfig_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

    $result = [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        Mode         = $Mode
        Status       = 'Unknown'
        Message      = ''
        IsConfigured = $false
        ServiceStatus = $null
    }

    $execTarget = if ($Remote) { 'Remote (AD OU)' } elseif ($ComputerList) { 'List' } else { 'Local' }
    _sqmSplunkGuiLog "Invoke-sqmSplunkConfiguration | Modus: $Mode | Ziel: $execTarget" $LogCallback $LogFile

    try
    {
        if ($Remote) {
            return (_sqmSplunk_ForOU -SearchOU $SearchOU -Mode $Mode -LogPath $LogPath -LogFile $LogFile `
                                     -Credential $Credential -LogCallback $LogCallback)
        }
        elseif ($ComputerList) {
            return (_sqmSplunk_ForList -ComputerList $ComputerList -Mode $Mode -LogPath $LogPath -LogFile $LogFile `
                                       -Credential $Credential -LogCallback $LogCallback)
        }
        else
        {
            # Local execution - must return PSCustomObject
            $coreOk = _sqmSplunk_LocalCore -LogFile $LogFile -Mode $Mode

            if ($coreOk -eq $false)
            {
                # LocalCore ist vorzeitig abgebrochen (z.B. fehlende Administratorrechte) - ohne
                # diese Pruefung wuerde unten anhand des unveraenderten Ist-Zustands faelschlich
                # 'Success'/'NotConfigured' gemeldet, obwohl gar nichts ausgefuehrt wurde.
                $result.Status  = 'Error'
                $result.Message = 'Administratorrechte erforderlich. PowerShell als Administrator starten und erneut ausfuehren.'
                return $result
            }

            # Check actual configuration
            $envVars = [Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::Machine)
            $splunkVars = @($envVars.Keys | Where-Object { $_ -like 'MSSQL*_Log' })
            $result.IsConfigured = $splunkVars.Count -gt 0

            $svc = Get-Service -Name 'SplunkForwarder' -ErrorAction SilentlyContinue
            $result.ServiceStatus = if ($svc) { $svc.Status.ToString() } else { 'NotFound' }

            if ($Mode -eq 'Remove')
            {
                $result.Status = if (-not $result.IsConfigured) { 'Success' } else { 'PartialFailure' }
                $result.Message = "Removed Splunk environment variables, Service: $($result.ServiceStatus)"
            }
            elseif ($result.IsConfigured)
            {
                $result.Status = 'Success'
                $result.Message = "Configured with $($splunkVars.Count) environment variable(s), Service: $($result.ServiceStatus)"
            }
            else
            {
                $result.Status = 'NotConfigured'
                $result.Message = 'No Splunk environment variables found'
            }

            return $result
        }
    }
    catch
    {
        $result.Status = 'Error'
        $result.Message = $_.Exception.Message
        return $result
    }
}
