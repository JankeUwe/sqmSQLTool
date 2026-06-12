<#
.SYNOPSIS
Lightweight job script: Compare logins across AlwaysOn replicas
Core version - no module dependencies, DirectWrite for reports

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
# Main: Compare logins (core version)
# ===================================================================

$SqlInstance = $env:COMPUTERNAME
$OutputPath = "C:\System\WinSrvLog\MSSQL"
$results = @()

try {
    Write-JobLog "START: Compare-sqmAlwaysOnLogins auf $SqlInstance"

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    # 1. Get AG (first one)
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
    $replicaNames = @($replicas | Select-Object -ExpandProperty Name)
    Write-JobLog "Replicas: $($replicaNames -join ', ')"

    if ($replicaNames.Count -lt 2) {
        Write-JobLog "WARNUNG: Weniger als 2 Replicas"
        exit 0
    }

    # 3. Get logins from each replica
    $loginQuery = @"
SELECT
    sp.name AS LoginName,
    sp.type_desc AS LoginType,
    sp.default_database_name AS DefaultDatabase,
    sp.default_language_name AS DefaultLanguage,
    CONVERT(varchar(85), sp.sid, 1) AS SidHex
FROM sys.server_principals sp
WHERE sp.type IN ('S','U','G')
  AND sp.name NOT LIKE '##%##'
  AND sp.name NOT LIKE 'sa'
  AND sp.name NOT LIKE 'NT SERVICE\%'
  AND sp.name NOT LIKE 'BUILTIN\%'
"@

    $replicaData = @{}
    foreach ($replica in $replicaNames) {
        try {
            $rows = Invoke-DbaQuery -SqlInstance $replica -Query $loginQuery -ErrorAction Stop
            $map = @{}
            foreach ($row in $rows) {
                $map[$row.LoginName.ToLowerInvariant()] = $row
            }
            $replicaData[$replica] = $map
            Write-JobLog "OK: $($map.Count) Logins von $replica"
        }
        catch {
            Write-JobLog "WARNUNG: $replica nicht erreichbar - $_" 'WARNING'
            $replicaData[$replica] = $null
        }
    }

    # 4. Compare logins
    $allLogins = @{}
    foreach ($replica in $replicaNames) {
        if ($replicaData[$replica]) {
            foreach ($login in $replicaData[$replica].Keys) {
                if (-not $allLogins.ContainsKey($login)) {
                    $allLogins[$login] = $replicaData[$replica][$login].LoginName
                }
            }
        }
    }

    Write-JobLog "Vergleiche $($allLogins.Count) Logins"

    # 5. Build report
    $lines = @()
    $lines += "# ================================================================="
    $lines += "# Compare-sqmAlwaysOnLogins Report"
    $lines += "# AG: $agName"
    $lines += "# Replicas: $($replicaNames -join ', ')"
    $lines += "# Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "# ================================================================="
    $lines += ""
    $lines += "{0,-35} {1,-35} {2,-10} {3}" -f "Login", "Replicas", "Status", "Befund"
    $lines += "-" * 95

    $cntOk = 0
    $cntWarn = 0
    $cntCrit = 0

    foreach ($loginKey in ($allLogins.Keys | Sort-Object)) {
        $display = $allLogins[$loginKey]
        $presentOn = @()
        $missingOn = @()
        $sidMatch = $true

        foreach ($replica in $replicaNames) {
            if ($replicaData[$replica] -and $replicaData[$replica].ContainsKey($loginKey)) {
                $presentOn += $replica
            } else {
                $missingOn += $replica
            }
        }

        if ($missingOn.Count -gt 0) {
            $status = "Critical"
            $befund = "Fehlt auf: $($missingOn -join ',')"
            $cntCrit++
        } else {
            $status = "OK"
            $befund = "Konsistent"
            $cntOk++
        }

        $loginShort = if ($display.Length -gt 35) { $display.Substring(0, 32) + '...' } else { $display }
        $lines += "{0,-35} {1,-35} {2,-10} {3}" -f $loginShort, "$($presentOn.Count)/$($replicaNames.Count)", $status, $befund
    }

    $lines += ""
    $lines += "# Summary: OK=$cntOk | Warning=$cntWarn | Critical=$cntCrit"

    # 6. Write report (DirectWrite - no .temp files!)
    $timestamp = Get-Date -Format 'yyyy-MM-dd'
    $safeAg = $agName -replace '[\\/:*?"<>|]', '_'
    $reportFile = Join-Path $OutputPath "AlwaysOnLoginCompare_${safeAg}_${timestamp}.txt"

    [System.IO.File]::WriteAllText($reportFile, ($lines -join "`n"), [System.Text.Encoding]::UTF8)
    Write-JobLog "Report geschrieben: $reportFile"

    Write-JobLog "FERTIG: Compare-sqmAlwaysOnLogins abgeschlossen (OK=$cntOk, Critical=$cntCrit)"
    exit 0
}
catch {
    Write-JobLog "GLOBALER FEHLER: $_" 'ERROR'
    exit 1
}
