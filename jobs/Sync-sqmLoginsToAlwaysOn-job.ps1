<#
.SYNOPSIS
Lightweight job script: Sync logins to AlwaysOn secondaries
Core version - no module dependencies for login copy logic

Generated for SQL Agent CmdExec execution
#>

$ErrorActionPreference = 'Stop'

# Load dbatools
try {
    if (-not (Get-Module -Name dbatools)) {
        Import-Module dbatools -ErrorAction Stop
    }
} catch {
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] FEHLER: dbatools nicht verfügbar" | Write-Host
    exit 1
}

# Logging helper
function Write-JobLog {
    param([string]$Message, [string]$Level = 'INFO')
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" | Write-Host
}

# ===================================================================
# Main: Sync logins (core version)
# ===================================================================

$SqlInstance = $env:COMPUTERNAME
$BackupPath = "C:\System\WinSrvLog\MSSQL"
$Force = $true
$BackupLogins = $true

try {
    Write-JobLog "START: Sync-sqmLoginsToAlwaysOn auf $SqlInstance"

    # 1. Get AG
    $allAGs = Get-DbaAvailabilityGroup -SqlInstance $SqlInstance -ErrorAction Stop
    if (-not $allAGs) {
        Write-JobLog "WARNUNG: Keine AGs gefunden" 'WARNING'
        exit 0
    }
    $ag = $allAGs | Select-Object -First 1
    $agName = $ag.Name
    Write-JobLog "AG: $agName"

    # 2. Get replicas
    $replicas = Get-DbaAgReplica -SqlInstance $SqlInstance -AvailabilityGroup $agName -ErrorAction Stop
    $primary = $replicas | Where-Object { $_.Role -eq 'Primary' } | Select-Object -First 1
    $secondaries = $replicas | Where-Object { $_.Role -eq 'Secondary' }

    if (-not $primary) {
        Write-JobLog "FEHLER: Keine Primary gefunden" 'ERROR'
        exit 1
    }

    Write-JobLog "Primary: $($primary.Name)"
    Write-JobLog "Secondaries: $($secondaries.Name -join ', ')"

    # 3. Get logins from primary
    Write-JobLog "Lese Logins von Primary: $($primary.Name)"
    $logins = Get-DbaLogin -SqlInstance $primary.Name -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'sa' -and $_.Name -notlike 'NT SERVICE\%' -and $_.Name -notlike 'BUILTIN\%' }

    if (-not $logins) {
        Write-JobLog "Keine Logins zum Synchronisieren"
        exit 0
    }

    Write-JobLog "OK: $($logins.Count) Logins gefunden"

    # 4. Sync to each secondary
    foreach ($secondary in $secondaries) {
        $secName = $secondary.Name
        Write-JobLog "Synchronisiere zu Secondary: $secName"

        try {
            # Backup existing logins if requested
            if ($BackupLogins) {
                try {
                    if (-not (Test-Path $BackupPath)) {
                        New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
                    }

                    $backupQuery = @"
SELECT 'USE master; ' + CHAR(13) + CHAR(10) +
       'IF NOT EXISTS(SELECT 1 FROM sys.sql_logins WHERE name = ' + QUOTENAME(sp.name, '''') + ')' + CHAR(13) + CHAR(10) +
       'BEGIN' + CHAR(13) + CHAR(10) +
       'CREATE LOGIN ' + QUOTENAME(sp.name) + ' WITH PASSWORD = ' + QUOTENAME(CONVERT(varchar(256), sl.password_hash, 1), '''') + ' HASHED; ' + CHAR(13) + CHAR(10) +
       'END' + CHAR(13) + CHAR(10)
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins sl ON sl.principal_id = sp.principal_id
WHERE sp.type IN ('S', 'U', 'G')
  AND sp.name NOT LIKE 'sa'
  AND sp.name NOT LIKE '##%'
"@

                    $backupContent = Invoke-DbaQuery -SqlInstance $secondary.Name -Query $backupQuery -ErrorAction SilentlyContinue
                    if ($backupContent) {
                        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                        $backupFile = Join-Path $BackupPath "LoginBackup_${secName}_${timestamp}.sql"
                        [System.IO.File]::WriteAllText($backupFile, ($backupContent | Out-String), [System.Text.Encoding]::UTF8)
                        Write-JobLog "Backup erstellt: $backupFile"
                    }
                } catch {
                    Write-JobLog "WARNUNG: Backup fehlgeschlagen - $_" 'WARNING'
                }
            }

            # Copy logins using dbatools (Copy-DbaLogin is the standard way)
            Write-JobLog "Kopiere Logins von $($primary.Name) zu $secName"
            Copy-DbaLogin -Source $primary.Name -Destination $secName -Login $logins.Name `
                -Force:$Force -ErrorAction Stop | Out-Null

            Write-JobLog "OK: Logins synchronisiert zu $secName"
        }
        catch {
            Write-JobLog "FEHLER: Sync zu $secName fehlgeschlagen - $_" 'ERROR'
        }
    }

    Write-JobLog "FERTIG: Sync-sqmLoginsToAlwaysOn abgeschlossen"
    exit 0
}
catch {
    Write-JobLog "GLOBALER FEHLER: $_" 'ERROR'
    exit 1
}
