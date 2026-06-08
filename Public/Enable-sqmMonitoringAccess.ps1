<#
.SYNOPSIS
    Richtet einen Monitoring-Account auf allen SQL Server-Instanzen eines Computers ein.

.DESCRIPTION
    Findet alle SQL Server-Instanzen auf dem Zielcomputer per Registry-Abfrage,
    verbindet sich mit jeder Instanz und richtet folgende Objekte ein:

    - Server-Rolle ($ServerRoleName) mit den notwendigen Server-Berechtigungen
    - Login ($MonitoringUser) als Windows-Login
    - Datenbank-Rolle ($DatabaseRoleName) in master und msdb
    - Datenbankbenutzer und Rollenzuordnung in master und msdb
    - Granulare GRANT-Berechtigungen auf System-Views und Stored Procedures

    Optional: Eine SQL Server Policy kann vor dem Setup deaktiviert und
    danach wieder aktiviert werden (-PolicyName).

    Ausgabe:
        MonitoringAccess_<computer>_<datum>.log  - Protokoll der ausgefuehrten Schritte

.PARAMETER ComputerName
    Zielcomputer. Standard: aktueller Computer.

.PARAMETER MonitoringUser
    Windows-Login des Monitoring-Accounts (z.B. "DOMAIN\MonUser").

.PARAMETER ServerRoleName
    Name der SQL Server-Rolle die angelegt wird. Standard: "MonitoringRole".

.PARAMETER DatabaseRoleName
    Name der Datenbank-Rolle die in master und msdb angelegt wird.
    Standard: "MonitoringDbRole".

.PARAMETER PolicyName
    Name einer SQL Server Policy die vor dem Setup deaktiviert und danach
    wieder aktiviert wird. Wird der Parameter weggelassen, wird keine Policy
    veraendert.

.PARAMETER OutputPath
    Ausgabeverzeichnis fuer das Log. Standard: C:\System\WinSrvLog\MSSQL

.PARAMETER SqlCredential
    Optionales PSCredential fuer die SQL Server-Verbindung.

.PARAMETER ContinueOnError
    Bei Fehler auf einer Instanz fortfahren statt abbrechen.

.PARAMETER EnableException
    Fehler als terminierende Ausnahmen ausloesen.

.EXAMPLE
    Enable-sqmMonitoringAccess -MonitoringUser "CORP\SvcMonitoring"

.EXAMPLE
    Enable-sqmMonitoringAccess -ComputerName "SQL01" -MonitoringUser "CORP\SvcMonitoring" `
        -ServerRoleName "MonRole" -DatabaseRoleName "MonDbRole" `
        -PolicyName "Enforce Password Policy" -ContinueOnError

.NOTES
    Benoetigt: dbaTools, Ausfuehrung als lokaler Administrator auf dem Zielcomputer.
    Die Registry-Abfrage (InstalledInstances) findet alle Instanzen automatisch.
#>
function Enable-sqmMonitoringAccess
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory = $false)]
        [string]$MonitoringUser,

        [Parameter(Mandatory = $false)]
        [string]$ServerRoleName = 'MonitoringRole',

        [Parameter(Mandatory = $false)]
        [string]$DatabaseRoleName = 'MonitoringDbRole',

        [Parameter(Mandatory = $false)]
        [string]$PolicyName,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath = 'C:\System\WinSrvLog\MSSQL',

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential,

        [Parameter(Mandatory = $false)]
        [switch]$ContinueOnError,

        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name
        $results      = [System.Collections.Generic.List[PSCustomObject]]::new()
        $logLines     = [System.Collections.Generic.List[string]]::new()

        function _Log
        {
            param ([string]$Msg, [string]$Level = 'INFO')
            $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $line = "[$ts] [$Level] $Msg"
            $logLines.Add($line)
            Invoke-sqmLogging -Message $Msg -FunctionName $functionName -Level $Level
        }

        # ------------------------------------------------------------------
        # Private Hilfsfunktionen
        # ------------------------------------------------------------------

        function _EnsureServerRole
        {
            param ([string]$SqlInstance, [string]$RoleName)
            $q = "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE type = 'R' AND name = N'$RoleName')
                  BEGIN
                      CREATE SERVER ROLE [$RoleName] AUTHORIZATION [sa];
                  END"
            Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database master -Query $q -EnableException:$EnableException
            _Log "[$SqlInstance] Server-Rolle '$RoleName' sichergestellt."
        }

        function _SetServerRolePermissions
        {
            param ([string]$SqlInstance, [string]$RoleName)
            $grants = @(
                "GRANT VIEW SERVER STATE      TO [$RoleName]",
                "GRANT VIEW ANY DATABASE      TO [$RoleName]",
                "GRANT VIEW ANY DEFINITION    TO [$RoleName]",
                "GRANT ALTER TRACE            TO [$RoleName]",
                "GRANT CONNECT ANY DATABASE   TO [$RoleName]"
            )
            foreach ($g in $grants)
            {
                Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database master -Query $g -EnableException:$EnableException
            }
            _Log "[$SqlInstance] Server-Berechtigungen fuer '$RoleName' gesetzt."
        }

        function _EnsureLogin
        {
            param ([string]$SqlInstance, [string]$LoginName)
            $q = "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$LoginName')
                  BEGIN
                      CREATE LOGIN [$LoginName] FROM WINDOWS WITH DEFAULT_DATABASE = [master];
                  END"
            Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database master -Query $q -EnableException:$EnableException
            _Log "[$SqlInstance] Login '$LoginName' sichergestellt."
        }

        function _AddLoginToServerRole
        {
            param ([string]$SqlInstance, [string]$LoginName, [string]$RoleName)
            $q = "ALTER SERVER ROLE [$RoleName] ADD MEMBER [$LoginName]"
            Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database master -Query $q -EnableException:$EnableException
            _Log "[$SqlInstance] Login '$LoginName' zu Server-Rolle '$RoleName' hinzugefuegt."
        }

        function _EnsureDbRole
        {
            param ([string]$SqlInstance, [string]$Database, [string]$RoleName)
            $q = "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE type = 'R' AND name = N'$RoleName')
                  BEGIN
                      CREATE ROLE [$RoleName] AUTHORIZATION [dbo];
                  END"
            Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database -Query $q -EnableException:$EnableException
            _Log "[$SqlInstance] DB-Rolle '$RoleName' in '$Database' sichergestellt."
        }

        function _AddLoginToDbRole
        {
            param ([string]$SqlInstance, [string]$Database, [string]$LoginName, [string]$RoleName)
            # Datenbankbenutzer anlegen falls nicht vorhanden
            $qUser = "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$LoginName')
                      BEGIN
                          CREATE USER [$LoginName] FOR LOGIN [$LoginName];
                      END"
            Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database -Query $qUser -EnableException:$EnableException

            # Rollenmitgliedschaft
            $qRole = "ALTER ROLE [$RoleName] ADD MEMBER [$LoginName]"
            Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $Database -Query $qRole -EnableException:$EnableException
            _Log "[$SqlInstance] '$LoginName' in '$Database' zur Rolle '$RoleName' hinzugefuegt."
        }

        function _SetMasterPermissions
        {
            param ([string]$SqlInstance, [string]$DbRoleName, [string]$SvrRoleName)
            $grants = @(
                "GRANT SELECT ON SYS.ALL_OBJECTS          TO [$DbRoleName]",
                "GRANT SELECT ON SYS.CONFIGURATIONS       TO [$DbRoleName]",
                "GRANT SELECT ON SYS.DATABASES            TO [$DbRoleName]",
                "GRANT SELECT ON SYS.DATABASE_PERMISSIONS TO [$DbRoleName]",
                "GRANT SELECT ON SYS.SYSLOGINS            TO [$DbRoleName]",
                "GRANT SELECT ON SYS.TRACES               TO [$DbRoleName]",
                "GRANT SELECT ON SYS.SYSALTFILES          TO [$DbRoleName]",
                "GRANT SELECT ON SYS.SERVER_PRINCIPALS    TO [$DbRoleName]",
                "GRANT EXECUTE ON XP_LOGINCONFIG          TO [$DbRoleName]",
                "GRANT ALTER TRACE                        TO [$SvrRoleName]",
                "GRANT VIEW SERVER STATE                  TO [$SvrRoleName]",
                "GRANT VIEW ANY DEFINITION                TO [$SvrRoleName]"
            )
            foreach ($g in $grants)
            {
                Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database master -Query $g -EnableException:$EnableException
            }
            _Log "[$SqlInstance] master-Berechtigungen gesetzt."
        }

        function _SetMsdbPermissions
        {
            param ([string]$SqlInstance, [string]$DbRoleName)
            $grants = @(
                "GRANT EXECUTE ON MSDB.dbo.sp_enum_login_for_proxy     TO [$DbRoleName]",
                "GRANT EXECUTE ON MSDB.dbo.sp_enum_proxy_for_subsystem TO [$DbRoleName]",
                "GRANT SELECT  ON MSDB.dbo.sysproxies                  TO [$DbRoleName]",
                "GRANT SELECT  ON MSDB.dbo.sysproxylogin               TO [$DbRoleName]"
            )
            foreach ($g in $grants)
            {
                Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database msdb -Query $g -EnableException:$EnableException
            }
            _Log "[$SqlInstance] msdb-Berechtigungen gesetzt."
        }

        function _SetPolicyState
        {
            param ([string]$SqlInstance, [string]$Policy, [bool]$Enable)
            $state = if ($Enable) { 1 } else { 0 }
            $q = "UPDATE msdb.dbo.syspolicies_policies SET is_enabled = $state WHERE name = N'$Policy'"
            Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Query $q -EnableException:$EnableException
            $stateText = if ($Enable) { 'aktiviert' } else { 'deaktiviert' }
            _Log "[$SqlInstance] Policy '$Policy' $stateText."
        }

        # ------------------------------------------------------------------
        # Config-Werte auflösen — Parameter überschreiben Settings
        # ------------------------------------------------------------------

        if (-not $PSBoundParameters.ContainsKey('MonitoringUser') -or -not $MonitoringUser)
        {
            $MonitoringUser = Get-sqmConfig -Key 'DefaultMonitoringUser'
        }
        if (-not $MonitoringUser)
        {
            $msg = "Kein Monitoring-User angegeben und 'DefaultMonitoringUser' ist nicht in den Settings konfiguriert. Abbruch."
            Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
            throw $msg
        }

        if (-not $PSBoundParameters.ContainsKey('PolicyName') -or -not $PolicyName)
        {
            $PolicyName = Get-sqmConfig -Key 'DefaultPolicy'
            # $null oder leer = kein Policy-Handling gewuenscht
        }

        # ------------------------------------------------------------------
        # Registry: Instanzen auf Zielcomputer ermitteln
        # ------------------------------------------------------------------

        _Log "Starte $functionName auf '$ComputerName'. Monitoring-Account: '$MonitoringUser'$(if ($PolicyName) { ", Policy: '$PolicyName'" })"

        if (-not (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet))
        {
            $msg = "Computer '$ComputerName' nicht erreichbar (Ping)."
            _Log $msg 'ERROR'
            if ($EnableException) { throw $msg }
            return [PSCustomObject]@{ ComputerName = $ComputerName; Status = 'Error'; Message = $msg }
        }

        try
        {
            $hive    = [Microsoft.Win32.RegistryHive]::LocalMachine
            $regPath = 'SOFTWARE\Microsoft\Microsoft SQL Server'
            $base    = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey($hive, $ComputerName)
            $key     = $base.OpenSubKey($regPath)

            if (-not $key)
            {
                $msg = "Registry-Key '$regPath' nicht gefunden auf '$ComputerName' — kein SQL Server installiert?"
                _Log $msg 'ERROR'
                if ($EnableException) { throw $msg }
                return [PSCustomObject]@{ ComputerName = $ComputerName; Status = 'Error'; Message = $msg }
            }

            $instances = $key.GetValue('InstalledInstances')
            _Log "$($instances.Count) SQL Server-Instanz(en) auf '$ComputerName' gefunden: $($instances -join ', ')"
        }
        catch
        {
            $msg = "Registry-Abfrage auf '$ComputerName' fehlgeschlagen: $($_.Exception.Message)"
            _Log $msg 'ERROR'
            if ($EnableException) { throw }
            return [PSCustomObject]@{ ComputerName = $ComputerName; Status = 'Error'; Message = $msg }
        }
    }

    process
    {
        foreach ($instance in $instances)
        {
            $sqlInstance = if ($instance -eq 'MSSQLSERVER') { $ComputerName }
                           else { "$ComputerName\$instance" }

            $instanceResult = [PSCustomObject]@{
                ComputerName  = $ComputerName
                SqlInstance   = $sqlInstance
                Status        = 'OK'
                Message       = ''
            }

            try
            {
                if (-not $PSCmdlet.ShouldProcess($sqlInstance, "Monitoring-Berechtigungen einrichten fuer '$MonitoringUser'"))
                {
                    _Log "[$sqlInstance] WhatIf: Keine Aenderungen vorgenommen." 'VERBOSE'
                    $instanceResult.Status = 'WhatIf'
                    $results.Add($instanceResult)
                    continue
                }

                # Verbindung testen
                $connTest = Connect-DbaInstance -SqlInstance $sqlInstance -SqlCredential $SqlCredential -ErrorAction Stop
                if (-not $connTest)
                {
                    throw "Verbindung zu '$sqlInstance' fehlgeschlagen."
                }
                _Log "[$sqlInstance] Verbindung hergestellt."

                # Policy deaktivieren (optional)
                if ($PolicyName)
                {
                    _SetPolicyState -SqlInstance $sqlInstance -Policy $PolicyName -Enable $false
                }

                # Server-Rolle und Berechtigungen
                _EnsureServerRole            -SqlInstance $sqlInstance -RoleName $ServerRoleName
                _SetServerRolePermissions    -SqlInstance $sqlInstance -RoleName $ServerRoleName

                # Login
                _EnsureLogin                 -SqlInstance $sqlInstance -LoginName $MonitoringUser
                _AddLoginToServerRole        -SqlInstance $sqlInstance -LoginName $MonitoringUser -RoleName $ServerRoleName

                # Datenbank-Rollen und Benutzer
                _EnsureDbRole                -SqlInstance $sqlInstance -Database master -RoleName $DatabaseRoleName
                _EnsureDbRole                -SqlInstance $sqlInstance -Database msdb   -RoleName $DatabaseRoleName
                _AddLoginToDbRole            -SqlInstance $sqlInstance -Database master -LoginName $MonitoringUser -RoleName $DatabaseRoleName
                _AddLoginToDbRole            -SqlInstance $sqlInstance -Database msdb   -LoginName $MonitoringUser -RoleName $DatabaseRoleName

                # Granulare Berechtigungen
                _SetMasterPermissions        -SqlInstance $sqlInstance -DbRoleName $DatabaseRoleName -SvrRoleName $ServerRoleName
                _SetMsdbPermissions          -SqlInstance $sqlInstance -DbRoleName $DatabaseRoleName

                # Policy wieder aktivieren (optional)
                if ($PolicyName)
                {
                    _SetPolicyState -SqlInstance $sqlInstance -Policy $PolicyName -Enable $true
                }

                _Log "[$sqlInstance] Setup erfolgreich abgeschlossen."
            }
            catch
            {
                $errMsg = "[$sqlInstance] Fehler: $($_.Exception.Message)"
                _Log $errMsg 'ERROR'
                $instanceResult.Status  = 'Error'
                $instanceResult.Message = $_.Exception.Message

                if ($PolicyName)
                {
                    # Policy sicherheitshalber reaktivieren auch im Fehlerfall
                    try { _SetPolicyState -SqlInstance $sqlInstance -Policy $PolicyName -Enable $true }
                    catch { _Log "[$sqlInstance] Policy-Reaktivierung nach Fehler fehlgeschlagen: $($_.Exception.Message)" 'WARNING' }
                }

                if ($EnableException) { throw }
                if (-not $ContinueOnError) { throw $_ }
            }

            $results.Add($instanceResult)
        }
    }

    end
    {
        # Log-Datei schreiben
        try
        {
            if (-not (Test-Path $OutputPath))
            {
                New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
            }
            $datestamp = Get-Date -Format 'yyyy-MM-dd'
            $safeComp  = $ComputerName -replace '[\\/:*?"<>|]', '_'
            $logFile   = Join-Path $OutputPath "MonitoringAccess_${safeComp}_${datestamp}.log"
            $logLines | Out-File -FilePath $logFile -Encoding UTF8 -Force
            _Log "Log gespeichert: $logFile"
        }
        catch
        {
            Invoke-sqmLogging -Message "Log-Datei konnte nicht geschrieben werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
        }

        _Log "$functionName abgeschlossen. $($results.Count) Instanz(en) verarbeitet."
        return $results
    }
}
