<#
.SYNOPSIS
    Erstellt einen SQL Server Credential und einen SQL Agent Proxy und verbindet beide.

.DESCRIPTION
    Legt in einem Schritt einen neuen SQL Server Credential an und erstellt darauf
    basierend einen SQL Server Agent Proxy. Die Windows-Credentials werden interaktiv
    per Get-Credential abgefragt. Der Account wird vor der Erstellung auf Existenz
    und Eignung geprueft (Enabled, nicht gesperrt, Passwort nicht abgelaufen,
    Konto nicht abgelaufen). Ueber -Subsystem wird gesteuert welche Subsysteme
    dem Proxy zugewiesen werden.

    Ablauf:
      1. Get-Credential Dialog - Windows-Account eingeben
      2. AD-Pruefung: Existenz, Enabled, LockedOut, PasswordExpired, AccountExpired
      3. Pruefen ob Credential bereits existiert (Fehler oder -Force)
      4. Credential anlegen (CREATE CREDENTIAL) via SMO
      5. Pruefen ob Proxy bereits existiert (Fehler oder -Force)
      6. Agent Proxy anlegen und mit dem Credential verbinden via SMO
      7. Subsysteme gemaess -Subsystem zuweisen (CmdExec, SSIS, PowerShell oder All)
      8. Protokoll-Objekt zurueckgeben

.PARAMETER SqlInstance
    SQL Server-Instanz. Standard: lokaler Computername.

.PARAMETER SqlCredential
    PSCredential fuer die SQL-Verbindung (Windows-Auth wenn nicht angegeben).

.PARAMETER CredentialName
    Name des neuen SQL Server Credentials (z.B. "DOMAIN\ServiceAccount").

.PARAMETER ProxyName
    Name des neuen SQL Agent Proxys.

.PARAMETER ProxyDescription
    Optionale Beschreibung fuer den Proxy.

.PARAMETER WindowsCredential
    Windows-Credential direkt als PSCredential uebergeben (kein Dialog).
    Wenn nicht angegeben erscheint ein Get-Credential Dialog.
    Kann z.B. aus einem Passwort-Safe oder vorherigem Get-Credential stammen.

.PARAMETER WindowsUserName
    Optionaler Windows-Benutzername (DOMAIN\User) zur Vorbestueckung des
    Get-Credential Dialogs. Wird ignoriert wenn -WindowsCredential angegeben.
    Wenn nicht angegeben wird der CredentialName als Vorschlag verwendet.

.PARAMETER Subsystem
    Subsysteme die dem Proxy zugewiesen werden. Mehrfachauswahl moeglich.
    Gueltiger Werte: CmdExec, SSIS, PowerShell, All
    Standard: All (alle drei Subsysteme)

.PARAMETER Force
    Ueberschreibt bestehenden Credential und/oder Proxy wenn vorhanden.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen statt Write-Error.

.EXAMPLE
    # Einzeiler - Credential-Dialog erscheint automatisch
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SqlServiceAccount" `
        -ProxyName "SSIS Proxy"

    # Credential direkt uebergeben - kein Dialog
    $cred = Get-Credential "DOMAIN\SvcSSIS"
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SvcSSIS" `
        -ProxyName "SSIS Proxy" -WindowsCredential $cred

.EXAMPLE
    # Nur SSIS - Benutzername vorausgewaehlt im Dialog
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SvcSSIS" `
        -ProxyName "SSIS Only Proxy" -Subsystem SSIS

.EXAMPLE
    # CmdExec und PowerShell
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SvcPS" `
        -ProxyName "Script Proxy" -Subsystem CmdExec, PowerShell

.EXAMPLE
    # Abweichender Windows-Account und Force
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "ProxyCred_SSIS" `
        -ProxyName "SSIS Proxy" -WindowsUserName "DOMAIN\SvcSSIS" -Force

.EXAMPLE
    # Unattended / Skript-Betrieb mit SecureString aus Vault
    $secPwd = ConvertTo-SecureString "P@ssw0rd" -AsPlainText -Force
    $cred   = New-Object System.Management.Automation.PSCredential("DOMAIN\SvcSSIS", $secPwd)
    New-sqmAgentProxy -SqlInstance "SQL01" -CredentialName "DOMAIN\SvcSSIS" `
        -ProxyName "SSIS Proxy" -WindowsCredential $cred -Subsystem SSIS
    New-sqmAgentProxy -SqlInstance "SQL01\INST1" -CredentialName "DOMAIN\SvcSSIS" `
        -ProxyName "SSIS Execution Proxy" -ProxyDescription "Fuehrt SSIS-Pakete aus" `
        -WindowsCredential $winCred -Force

.NOTES
    Erfordert: SMO (Microsoft.SqlServer.Smo), Invoke-sqmLogging
    Benoetigt: sysadmin auf der Instanz
    Subsysteme: CmdExec (1), SSIS (11), PowerShell (12)
#>
function New-sqmAgentProxy
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$SqlInstance,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential,

        [Parameter(Mandatory = $true)]
        [string]$CredentialName,

        [Parameter(Mandatory = $true)]
        [string]$ProxyName,

        [Parameter(Mandatory = $false)]
        [string]$ProxyDescription = '',

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$WindowsCredential,

        [Parameter(Mandatory = $false)]
        [string]$WindowsUserName,

        [Parameter(Mandatory = $false)]
        [ValidateSet('CmdExec', 'SSIS', 'PowerShell', 'All')]
        [string[]]$Subsystem = @('All'),

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name

        if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
        {
            $SqlInstance = $env:COMPUTERNAME
        }

        # SMO Assembly laden
        try
        {
            [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.Smo')
            [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SqlEnum')
        }
        catch
        {
            $msg = "SMO konnte nicht geladen werden: $($_.Exception.Message)"
            Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
            if ($EnableException) { throw $msg }
            Write-Error $msg
            return
        }

        Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level 'INFO'
    }

    process
    {
        try
        {
            # ---------------------------------------------------------------
            # 1. Windows-Credential ermitteln (Parameter oder Dialog)
            # ---------------------------------------------------------------
            if ($WindowsCredential)
            {
                Write-Host ""
                Write-Host "  Windows-Credential direkt uebernommen: $($WindowsCredential.UserName)" -ForegroundColor Cyan
                Invoke-sqmLogging -Message "WindowsCredential per Parameter: $($WindowsCredential.UserName)" -FunctionName $functionName -Level 'INFO'
            }
            else
            {
                $dialogUser = if ($WindowsUserName) { $WindowsUserName } else { $CredentialName }

                Write-Host ""
                Write-Host "  Windows-Account fuer Proxy '$ProxyName'" -ForegroundColor Cyan
                Write-Host "  Bitte Credentials eingeben ..." -ForegroundColor Gray

                $WindowsCredential = Get-Credential -UserName $dialogUser `
                    -Message "Windows-Account fuer SQL Agent Proxy '$ProxyName' auf $SqlInstance"

                if (-not $WindowsCredential)
                {
                    throw "Abgebrochen - kein Credential eingegeben."
                }
            }

            # ---------------------------------------------------------------
            # 2. AD-Konto pruefen
            # ---------------------------------------------------------------
            # SamAccountName aus DOMAIN\User oder user@domain extrahieren
            $rawUser = $WindowsCredential.UserName
            $samAccountName = if ($rawUser -match '\\')
            {
                $rawUser.Split('\')[1]
            }
            elseif ($rawUser -match '@')
            {
                $rawUser.Split('@')[0]
            }
            else
            {
                $rawUser
            }

            Write-Host "  Pruefe AD-Konto '$samAccountName' ..." -ForegroundColor Gray
            Invoke-sqmLogging -Message "AD-Pruefung fuer Konto '$samAccountName'." -FunctionName $functionName -Level 'INFO'

            $adStatus = Get-sqmADAccountStatus -SamAccountName $samAccountName -ErrorAction SilentlyContinue

            if (-not $adStatus -or $adStatus.ErrorMessage)
            {
                throw "AD-Konto '$samAccountName' nicht gefunden oder nicht erreichbar: $($adStatus.ErrorMessage)"
            }

            # Eignung pruefen
            $issues = [System.Collections.Generic.List[string]]::new()
            if (-not $adStatus.Enabled)       { $issues.Add("Konto ist deaktiviert") }
            if ($adStatus.LockedOut)          { $issues.Add("Konto ist gesperrt") }
            if ($adStatus.PasswordExpired)    { $issues.Add("Passwort abgelaufen") }
            if ($adStatus.AccountExpired)     { $issues.Add("Konto abgelaufen") }

            if ($issues.Count -gt 0)
            {
                $issueList = $issues -join ', '
                throw "AD-Konto '$samAccountName' ist nicht geeignet: $issueList"
            }

            Write-Host "  AD-Konto OK: $rawUser (Enabled, nicht gesperrt)" -ForegroundColor Green
            Invoke-sqmLogging -Message "AD-Konto '$samAccountName' geeignet (Source: $($adStatus.Source))." -FunctionName $functionName -Level 'INFO'

            # ---------------------------------------------------------------
            # 3. SMO-Verbindung aufbauen
            # ---------------------------------------------------------------
            $serverConn = New-Object Microsoft.SqlServer.Management.Smo.Server($SqlInstance)

            if ($SqlCredential)
            {
                $serverConn.ConnectionContext.LoginSecure = $false
                $serverConn.ConnectionContext.Login       = $SqlCredential.UserName
                $serverConn.ConnectionContext.SecurePassword = $SqlCredential.Password
            }

            # Verbindung testen
            $null = $serverConn.Databases.Count
            Invoke-sqmLogging -Message "SMO-Verbindung zu $SqlInstance hergestellt (Version: $($serverConn.VersionString))." -FunctionName $functionName -Level 'INFO'

            # ---------------------------------------------------------------
            # 4. Credential anlegen
            # ---------------------------------------------------------------
            $existingCred = $serverConn.Credentials | Where-Object { $_.Name -eq $CredentialName }

            if ($existingCred)
            {
                if ($Force)
                {
                    Invoke-sqmLogging -Message "Credential '$CredentialName' existiert bereits - wird mit -Force geloescht und neu angelegt." -FunctionName $functionName -Level 'WARNING'
                    $existingCred.Drop()
                }
                else
                {
                    throw "Credential '$CredentialName' existiert bereits auf '$SqlInstance'. Verwende -Force zum Ueberschreiben."
                }
            }

            if (-not $PSCmdlet.ShouldProcess($SqlInstance, "Credential '$CredentialName' anlegen"))
            {
                return $null
            }

            $credential = New-Object Microsoft.SqlServer.Management.Smo.Credential($serverConn, $CredentialName)
            $credential.Identity = $WindowsCredential.UserName

            # Passwort als SecureString uebergeben
            $credential.Create($WindowsCredential.Password)

            Invoke-sqmLogging -Message "Credential '$CredentialName' (Identity: $($WindowsCredential.UserName)) erfolgreich angelegt." -FunctionName $functionName -Level 'INFO'

            # ---------------------------------------------------------------
            # 5. Agent Proxy anlegen
            # ---------------------------------------------------------------
            $jobServer      = $serverConn.JobServer
            $existingProxy  = $jobServer.ProxyAccounts | Where-Object { $_.Name -eq $ProxyName }

            if ($existingProxy)
            {
                if ($Force)
                {
                    Invoke-sqmLogging -Message "Proxy '$ProxyName' existiert bereits - wird mit -Force geloescht." -FunctionName $functionName -Level 'WARNING'
                    $existingProxy.Drop()
                }
                else
                {
                    throw "Proxy '$ProxyName' existiert bereits auf '$SqlInstance'. Verwende -Force zum Ueberschreiben."
                }
            }

            if (-not $PSCmdlet.ShouldProcess($SqlInstance, "Agent Proxy '$ProxyName' anlegen"))
            {
                return $null
            }

            $proxy = New-Object Microsoft.SqlServer.Management.Smo.Agent.ProxyAccount(
                $jobServer,
                $ProxyName,
                $CredentialName,
                $true,   # IsEnabled
                $ProxyDescription
            )

            $proxy.Create()
            Invoke-sqmLogging -Message "Agent Proxy '$ProxyName' mit Credential '$CredentialName' angelegt." -FunctionName $functionName -Level 'INFO'

            # ---------------------------------------------------------------
            # 6. Subsysteme zuweisen
            # ---------------------------------------------------------------
            # AgentSubSystem Enum-Werte:
            #   CmdExec     = 1
            #   Ssis        = 11
            #   PowerShell  = 12

            # Mapping: Parameterwert -> SMO Enum
            $subsystemMap = @{
                'CmdExec'    = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::CmdExec
                'SSIS'       = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::Ssis
                'PowerShell' = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::PowerShell
            }

            # 'All' aufloesen
            $resolved = if ($Subsystem -contains 'All')
            {
                $subsystemMap.Values
            }
            else
            {
                $Subsystem | ForEach-Object { $subsystemMap[$_] }
            }

            $assignedSubsystems = [System.Collections.Generic.List[string]]::new()

            foreach ($sub in $resolved)
            {
                $proxy.AddSubSystem($sub)
                $assignedSubsystems.Add($sub.ToString())
                Invoke-sqmLogging -Message "Subsystem '$sub' dem Proxy '$ProxyName' zugewiesen." -FunctionName $functionName -Level 'INFO'
            }

            # ---------------------------------------------------------------
            # 7. Ergebnis
            # ---------------------------------------------------------------
            $result = [PSCustomObject]@{
                SqlInstance          = $SqlInstance
                CredentialName       = $CredentialName
                CredentialIdentity   = $WindowsCredential.UserName
                ADAccountVerified    = $true
                ADAccountSource      = $adStatus.Source
                ProxyName            = $ProxyName
                ProxyDescription     = $ProxyDescription
                AssignedSubsystems   = $assignedSubsystems -join ', '
                IsEnabled            = $true
                Success              = $true
            }

            Write-Host ""
            Write-Host "  Agent Proxy erfolgreich erstellt" -ForegroundColor Green
            Write-Host "  --------------------------------" -ForegroundColor DarkGray
            Write-Host "  Instanz    : $SqlInstance"       -ForegroundColor Cyan
            Write-Host "  Credential : $CredentialName"    -ForegroundColor Cyan
            Write-Host "  Identity   : $($WindowsCredential.UserName)" -ForegroundColor Cyan
            Write-Host "  Proxy      : $ProxyName"         -ForegroundColor Cyan
            Write-Host "  Subsysteme : $($assignedSubsystems -join ', ')" -ForegroundColor Cyan
            Write-Host ""

            return $result
        }
        catch
        {
            $errMsg = "Fehler in $functionName`: $($_.Exception.Message)"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
            if ($EnableException) { throw }
            Write-Error $errMsg
            return [PSCustomObject]@{ Success = $false; ErrorMessage = $errMsg }
        }
    }

    end
    {
        Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level 'INFO'
    }
}
