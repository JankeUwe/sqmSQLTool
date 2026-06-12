<#
.SYNOPSIS
Lightweight job script: Repair AlwaysOn databases
Inline version - no module dependencies, direct execution by SQL Agent

Generated for SQL Agent CmdExec execution
#>

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

# Inline logging function
function Write-JobLog {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMsg = "[$timestamp] [$Level] $Message"
    Write-Host $logMsg
}

# Load dbatools
try {
    if (-not (Get-Module -Name dbatools)) {
        Import-Module dbatools -ErrorAction Stop
    }
} catch {
    Write-JobLog "FEHLER: dbatools-Modul nicht verfügbar: $_" 'ERROR'
    exit 1
}

# Helper: Ensure event log source
function Ensure-EventLogSource {
    param([string]$Source = 'sqmAlwaysOn')
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
            New-EventLog -LogName Application -Source $Source -ErrorAction SilentlyContinue | Out-Null
        }
    } catch { }
}

# ===================================================================
# Main: Repair-sqmAlwaysOnDatabases (inline version)
# ===================================================================

$SqlInstance = $env:COMPUTERNAME
$results = @()

try {
    Write-JobLog "START: Repair AlwaysOn Databases auf $SqlInstance"
    Ensure-EventLogSource

    # 1. Automatic Seeding enablen
    Write-JobLog "Prüfe Automatic Seeding auf allen Replicas"
    $allAGs = Get-DbaAvailabilityGroup -SqlInstance $SqlInstance -ErrorAction Stop
    if (-not $allAGs) {
        Write-JobLog "WARNUNG: Keine Availability Groups gefunden" 'WARNING'
        exit 0
    }

    # 2. Find problematic databases
    $problematicDatabases = @()
    foreach ($ag in $allAGs) {
        Write-JobLog "Prüfe AG: $($ag.Name)"
        $agDbs = Get-DbaAgDatabase -SqlInstance $SqlInstance -AvailabilityGroup $ag.Name
        foreach ($agDb in $agDbs) {
            $syncState = $agDb.SynchronizationState
            if ($syncState -ne 'HEALTHY' -and $syncState -ne 'SYNCHRONIZED') {
                $problematicDatabases += [PSCustomObject]@{
                    AvailabilityGroup = $ag.Name
                    DatabaseName      = $agDb.Name
                    CurrentState      = $syncState
                }
                Write-JobLog "WARNUNG: DB '$($agDb.Name)' in AG '$($ag.Name)' problematisch (Status: $syncState)" 'WARNING'
            }
        }
    }

    if ($problematicDatabases.Count -eq 0) {
        Write-JobLog "OK: Keine problematischen Datenbanken gefunden"
        exit 0
    }

    # 3. Repair each problematic database
    foreach ($prob in $problematicDatabases) {
        $dbName = $prob.DatabaseName
        $agName = $prob.AvailabilityGroup

        try {
            Write-JobLog "Starte Reparatur: DB='$dbName' AG='$agName'"

            # Remove from AG
            Remove-DbaAgDatabase -SqlInstance $SqlInstance -AvailabilityGroup $agName -Database $dbName -Confirm:$false -ErrorAction Stop
            Write-JobLog "Entfernt aus AG: $dbName"

            # Remove from secondaries
            $replicas = Get-DbaAgReplica -SqlInstance $SqlInstance -AvailabilityGroup $agName
            $secondaries = $replicas | Where-Object { $_.Role -eq 'Secondary' } | Select-Object -ExpandProperty Name
            foreach ($secondary in $secondaries) {
                $secDb = Get-DbaDatabase -SqlInstance $secondary -Database $dbName -ErrorAction SilentlyContinue
                if ($secDb) {
                    Remove-DbaDatabase -SqlInstance $secondary -Database $dbName -Confirm:$false -ErrorAction Stop
                    Write-JobLog "Gelöscht auf Secondary: $secondary\$dbName"
                }
            }

            # Ensure Full recovery
            $primaryDb = Get-DbaDatabase -SqlInstance $SqlInstance -Database $dbName
            if ($primaryDb.RecoveryModel -ne 'Full') {
                Set-DbaDbRecoveryModel -SqlInstance $SqlInstance -Database $dbName -RecoveryModel Full -ErrorAction Stop
                Write-JobLog "Recovery-Modus auf Full gesetzt: $dbName"
            }

            # Re-add with AutoSeed
            Add-DbaAgDatabase -SqlInstance $SqlInstance -AvailabilityGroup $agName -Database $dbName -SeedingMode Automatic -ErrorAction Stop
            Write-JobLog "OK: Reparatur erfolgreich - $dbName"

            Write-EventLog -LogName Application -Source 'sqmAlwaysOn' -EventId 1001 -EntryType Information `
                -Message "Reparatur erfolgreich: $dbName in AG $agName" -ErrorAction SilentlyContinue
        }
        catch {
            Write-JobLog "FEHLER: Reparatur fehlgeschlagen - $dbName - $_" 'ERROR'
            Write-EventLog -LogName Application -Source 'sqmAlwaysOn' -EventId 1002 -EntryType Error `
                -Message "Reparatur FEHLER: $dbName - $_" -ErrorAction SilentlyContinue
        }
    }

    Write-JobLog "FERTIG: Repair-AlwaysOnDatabases abgeschlossen"
    exit 0
}
catch {
    Write-JobLog "GLOBALER FEHLER: $_" 'ERROR'
    Write-EventLog -LogName Application -Source 'sqmAlwaysOn' -EventId 1003 -EntryType Error `
        -Message "Globaler Fehler: $_" -ErrorAction SilentlyContinue
    exit 1
}
