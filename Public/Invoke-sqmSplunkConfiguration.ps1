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

# Gibt Nachricht an GUI-Callback oder Write-Host aus (aeussere Funktionen)
function _sqmSplunkGuiLog {
    param([string]$Message, [ScriptBlock]$LogCallback)
    if ($LogCallback) { & $LogCallback $Message }
    else              { Write-Host $Message }
}

# Lokale Kernlogik: SQL-Instanzen ermitteln, Env-Vars setzen, Dienst verwalten.
# Wird als String serialisiert und via Invoke-Command remote ausgefuehrt.
# Darf KEINE externen Abhaengigkeiten haben.
# Verwendet _sqmSplunkWriteLog - wird zusammen mit dieser Funktion serialisiert.
function _sqmSplunk_LocalCore {
    param([string]$LogPath, [bool]$TestMode)

    $ErrorActionPreference = 'Continue'

    if (-not (Test-Path $LogPath)) {
        $null = New-Item -ItemType Directory -Path $LogPath -Force
    }
    $ts      = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logFile = Join-Path $LogPath "SplunkConfig_$ts.log"

    $modeLabel = if ($TestMode) { 'Test' } else { 'Set' }
    _sqmSplunkWriteLog $logFile "=== Invoke-sqmSplunkConfiguration | Modus: $modeLabel | $(hostname) ==="
    _sqmSplunkWriteLog $logFile "Logdatei: $logFile"

    if (-not $TestMode) {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            $msg = 'FEHLER: Administratorrechte erforderlich. PowerShell als Administrator starten und erneut ausfuehren.'
            _sqmSplunkWriteLog $logFile $msg
            Write-Warning $msg
            return
        }
    }

    $instKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (-not (Test-Path $instKey)) {
        _sqmSplunkWriteLog $logFile 'Keine SQL Server-Instanzen gefunden.'
        return
    }

    $instances     = Get-ItemProperty -Path $instKey
    $instanceNames = $instances.PSObject.Properties |
                     Where-Object { $_.Name -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider') } |
                     Select-Object -ExpandProperty Name

    if ($instanceNames.Count -eq 0) {
        _sqmSplunkWriteLog $logFile 'Keine Instanzen in der Registry eingetragen.'
        return
    }

    _sqmSplunkWriteLog $logFile "Instanzen gefunden: $($instanceNames.Count) ($($instanceNames -join ', '))"

    $i = 1
    foreach ($instName in $instanceNames) {
        $instID  = $instances.$instName
        $varName = "MSSQL${i}_Log"

        if ($TestMode) {
            $existing = [Environment]::GetEnvironmentVariable($varName, [EnvironmentVariableTarget]::Machine)
            if ($null -eq $existing) {
                _sqmSplunkWriteLog $logFile "TEST: '$varName' nicht gesetzt."
            } else {
                _sqmSplunkWriteLog $logFile "TEST: '$varName' = '$existing'"
            }
            $i++
            continue
        }

        _sqmSplunkWriteLog $logFile "Verarbeite Instanz $i : $instName (ID: $instID)"

        $current = [Environment]::GetEnvironmentVariable($varName, [EnvironmentVariableTarget]::Machine)
        if ($null -ne $current) {
            _sqmSplunkWriteLog $logFile "  '$varName' bereits gesetzt ('$current') - wird nicht ueberschrieben."
            $i++
            continue
        }

        try {
            $logDir = $null

            try {
                $asm = [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.Smo')
                if ($asm) {
                    $srvName = if ($instName -eq 'MSSQLSERVER') { '(local)' } else { "(local)\$instName" }
                    $srv    = New-Object Microsoft.SqlServer.Management.Smo.Server($srvName)
                    $logDir = $srv.ErrorLogPath
                }
            } catch { }

            if (-not $logDir) {
                $regP = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instID\MSSQLServer\Parameters"
                if (Test-Path $regP) {
                    $prm = Get-ItemProperty -Path $regP
                    $arg = ($prm.PSObject.Properties |
                            Where-Object { $_.Name -like 'SQLArg*' -and $_.Value -like '-e*' }).Value
                    if ($arg) {
                        $logDir = Split-Path ($arg -replace '^-e"?','' -replace '"$','')
                    }
                }
            }

            if (-not $logDir) { throw 'Pfad nicht ermittelbar.' }

            _sqmSplunkWriteLog $logFile "  ErrorLog-Pfad: $logDir"
            [Environment]::SetEnvironmentVariable($varName, $logDir, [EnvironmentVariableTarget]::Machine)
            _sqmSplunkWriteLog $logFile "  OK: '$varName' = '$logDir' gesetzt."
        } catch {
            _sqmSplunkWriteLog $logFile "  FEHLER bei $instName : $_"
        }

        $i++
    }

    $svcName = 'SplunkForwarder'
    $svc     = Get-Service -Name $svcName -ErrorAction SilentlyContinue

    if (-not $svc) {
        _sqmSplunkWriteLog $logFile "WARN: Dienst '$svcName' nicht vorhanden."
    } elseif ($TestMode) {
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
                Restart-Service -Name $svcName -Force
                _sqmSplunkWriteLog $logFile "Dienst '$svcName' neu gestartet."
            } catch {
                _sqmSplunkWriteLog $logFile "FEHLER beim Neustart: $_"
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
}

# Remote-Engine: fuehrt _sqmSplunk_LocalCore auf mehreren Rechnern aus
function _sqmSplunk_OnComputers {
    param(
        [string[]]$ComputerNames,
        [string]$Mode,
        [string]$LogPath,
        [System.Management.Automation.PSCredential]$Credential,
        [ScriptBlock]$LogCallback
    )

    if ($ComputerNames.Count -eq 0) {
        _sqmSplunkGuiLog 'Keine Computer angegeben.' $LogCallback
        return
    }

    _sqmSplunkGuiLog "$($ComputerNames.Count) Computer werden verarbeitet..." $LogCallback

    # Beide Funktionen serialisieren - _sqmSplunk_LocalCore benoetigt _sqmSplunkWriteLog remote
    $coreStr    = ${function:_sqmSplunk_LocalCore}.ToString()
    $writeStr   = ${function:_sqmSplunkWriteLog}.ToString()
    $testMode   = ($Mode -eq 'Test')
    $combined   = "function _sqmSplunkWriteLog {$writeStr} ; function _sqmSplunk_LocalCore {$coreStr}"

    $remoteBlock = {
        param([string]$LogPath, [bool]$TestMode, [string]$Combined)
        . ([ScriptBlock]::Create($Combined))
        _sqmSplunk_LocalCore -LogPath $LogPath -TestMode $TestMode
    }

    $splat = @{
        ScriptBlock  = $remoteBlock
        ArgumentList = @($LogPath, $testMode, $combined)
        ErrorAction  = 'Continue'
    }
    if ($Credential) { $splat['Credential'] = $Credential }

    $results = @()

    foreach ($name in $ComputerNames) {
        $name = $name.Trim()
        if (-not $name) { continue }

        _sqmSplunkGuiLog "Verbinde zu $name ..." $LogCallback
        $entry = [PSCustomObject]@{ Computer = $name; Status = ''; Fehler = '' }

        if (-not (Test-Connection -ComputerName $name -Count 1 -Quiet)) {
            Write-Warning "$name nicht erreichbar - wird uebersprungen."
            $entry.Status = 'Nicht erreichbar'
            $results += $entry
            continue
        }

        try {
            Invoke-Command -ComputerName $name @splat
            $entry.Status = 'Erfolgreich'
            _sqmSplunkGuiLog "  $name - OK" $LogCallback
        } catch {
            Write-Warning "Fehler bei $name : $_"
            $entry.Status = 'Fehler'
            $entry.Fehler = $_.Exception.Message
        }
        $results += $entry
    }

    _sqmSplunkGuiLog '' $LogCallback
    _sqmSplunkGuiLog '=== Zusammenfassung ===' $LogCallback
    $results | Format-Table -AutoSize
    return $results
}

# AD-OU-Modus
function _sqmSplunk_ForOU {
    param(
        [string]$SearchOU,
        [string]$Mode,
        [string]$LogPath,
        [System.Management.Automation.PSCredential]$Credential,
        [ScriptBlock]$LogCallback
    )

    Install-sqmAdModule

    $domainDN   = (Get-ADDomain).DistinguishedName
    $searchBase = if ($SearchOU -match '^OU=') { $SearchOU } else { "OU=$SearchOU,$domainDN" }

    _sqmSplunkGuiLog "AD-Suche unter: $searchBase" $LogCallback

    $adSplat = @{ Filter = '*'; SearchBase = $searchBase; Properties = 'OperatingSystem' }
    if ($Credential) { $adSplat['Credential'] = $Credential }

    $computers = Get-ADComputer @adSplat | Where-Object { $_.OperatingSystem -match 'Server' }

    if ($computers.Count -eq 0) {
        _sqmSplunkGuiLog "Keine Server in der OU '$SearchOU' gefunden." $LogCallback
        return
    }

    $names = $computers | Select-Object -ExpandProperty Name
    _sqmSplunkGuiLog "$($names.Count) Server in der OU gefunden." $LogCallback

    _sqmSplunk_OnComputers -ComputerNames $names -Mode $Mode `
                           -LogPath $LogPath -Credential $Credential -LogCallback $LogCallback
}

# Explizite Computerliste (Array oder Textdatei)
function _sqmSplunk_ForList {
    param(
        [string[]]$ComputerList,
        [string]$Mode,
        [string]$LogPath,
        [System.Management.Automation.PSCredential]$Credential,
        [ScriptBlock]$LogCallback
    )

    $resolved = @()

    foreach ($entry in $ComputerList) {
        $entry = $entry.Trim()
        if (-not $entry) { continue }

        if (Test-Path -LiteralPath $entry -PathType Leaf) {
            _sqmSplunkGuiLog "Lese Computernamen aus Datei: $entry" $LogCallback
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
        _sqmSplunkGuiLog 'Keine Computernamen in der Liste gefunden.' $LogCallback
        return
    }

    $unique = $resolved | Select-Object -Unique
    _sqmSplunkGuiLog "$($unique.Count) eindeutige Computer." $LogCallback

    _sqmSplunk_OnComputers -ComputerNames $unique -Mode $Mode `
                           -LogPath $LogPath -Credential $Credential -LogCallback $LogCallback
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
        Existing environment variables are not overwritten.
    .PARAMETER Mode
        Set  - Set environment variables and start/restart SplunkForwarder (default).
        Test - Check only, no changes.
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
    .NOTES
        Set mode requires local administrator rights.
        Remote: WinRM must be active on target servers.
        AD OU mode: ActiveDirectory module is automatically installed if needed.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Local')]
    param(
        [ValidateSet('Set', 'Test')]
        [string]$Mode = 'Set',

        [Parameter(ParameterSetName = 'Remote')]
        [switch]$Remote,

        [Parameter(ParameterSetName = 'Remote')]
        [string]$SearchOU = 'OUServDatabase',

        [Parameter(ParameterSetName = 'List')]
        [string[]]$ComputerList,

        [Parameter(ParameterSetName = 'Remote')]
        [Parameter(ParameterSetName = 'List')]
        [System.Management.Automation.PSCredential]$Credential,

        [string]$LogPath,

        [ScriptBlock]$LogCallback
    )

    if (-not $LogPath) {
        $LogPath = Get-sqmConfig -Key 'LogPath'
        if (-not $LogPath) { $LogPath = '$env:ProgramData\sqmSQLTool\Logs' }
    }

    $result = [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        Mode         = $Mode
        Status       = 'Unknown'
        Message      = ''
        IsConfigured = $false
        ServiceStatus = $null
    }

    _sqmSplunkGuiLog "Invoke-sqmSplunkConfiguration | Modus: $Mode | ParameterSet: $($PSCmdlet.ParameterSetName)" $LogCallback

    try
    {
        if ($Remote) {
            return (_sqmSplunk_ForOU -SearchOU $SearchOU -Mode $Mode `
                                     -LogPath $LogPath -Credential $Credential -LogCallback $LogCallback)
        }
        elseif ($ComputerList) {
            return (_sqmSplunk_ForList -ComputerList $ComputerList -Mode $Mode `
                                       -LogPath $LogPath -Credential $Credential -LogCallback $LogCallback)
        }
        else
        {
            # Local execution - must return PSCustomObject
            _sqmSplunk_LocalCore -LogPath $LogPath -TestMode ($Mode -eq 'Test')

            # Check actual configuration
            $envVars = [Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::Machine)
            $splunkVars = @($envVars.Keys | Where-Object { $_ -like 'MSSQL*_Log' })
            $result.IsConfigured = $splunkVars.Count -gt 0

            if ($result.IsConfigured)
            {
                $svc = Get-Service -Name 'SplunkForwarder' -ErrorAction SilentlyContinue
                $result.ServiceStatus = if ($svc) { $svc.Status.ToString() } else { 'NotFound' }
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
