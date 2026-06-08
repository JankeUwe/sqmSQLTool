<#
.SYNOPSIS
    Prueft ob eine SQL Server-Instanz auf dem lokalen System installiert ist.

.DESCRIPTION
    Kombiniert zwei Pruefmethoden:
        1. Registry: HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL
        2. Windows-Dienst: MSSQLSERVER (Default) oder MSSQL$<InstanceName> (Named)

    Gibt ein Objekt mit Installationsstatus, Version, Edition und Dienststatus zurueck.
    Rein lesender Zugriff - keine Aenderungen am System.

.PARAMETER InstanceName
    Name der zu pruefenden SQL-Instanz.
    Default: "MSSQLSERVER" (Default-Instanz).

.OUTPUTS
    [PSCustomObject] mit:
        InstanceName  : Instanzname
        IsInstalled   : $true wenn Registry-Eintrag vorhanden
        Version       : SQL Server-Version (z.B. "16.0.1000")
        Edition       : Edition aus Registry (z.B. "Developer Edition")
        ServiceName   : Windows-Dienstname
        ServiceState  : Running | Stopped | NotFound
        Status        : Installed | NotInstalled | Error
        Message       : Detailmeldung

.EXAMPLE
    Test-sqmSqlInstanceInstalled
    # Prueft Default-Instanz MSSQLSERVER

.EXAMPLE
    Test-sqmSqlInstanceInstalled -InstanceName 'INST01'

.EXAMPLE
    if ((Test-sqmSqlInstanceInstalled).IsInstalled) { Write-Host "SQL installiert" }

.NOTES
    Erfordert keine SQL-Verbindung - reine Registry/Dienst-Pruefung.
#>
function Test-sqmSqlInstanceInstalled
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$InstanceName = 'MSSQLSERVER'
    )

    $functionName  = $MyInvocation.MyCommand.Name
    $instanceUpper = $InstanceName.ToUpper()

    $result = [PSCustomObject]@{
        InstanceName = $instanceUpper
        IsInstalled  = $false
        Version      = $null
        Edition      = $null
        ServiceName  = $null
        ServiceState = 'NotFound'
        Status       = 'NotInstalled'
        Message      = $null
    }

    function _Log { param([string]$Msg, [string]$Level = 'INFO')
        Write-Verbose "[$functionName] $Msg"
        try { Invoke-sqmLogging -Message $Msg -FunctionName $functionName -Level $Level } catch { }
    }

    try
    {
        # --- 1. Registry-Pruefung ---
        $regInstances = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' `
            -ErrorAction SilentlyContinue

        $instanceRegKey = if ($regInstances) { $regInstances.$instanceUpper } else { $null }

        if ($instanceRegKey)
        {
            $result.IsInstalled = $true
            _Log "Registry: Instanz '$instanceUpper' gefunden (RegKey: $instanceRegKey)"

            # Version + Edition aus Registry
            $setupKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceRegKey\Setup"
            if (Test-Path $setupKey)
            {
                $setup = Get-ItemProperty -Path $setupKey -ErrorAction SilentlyContinue
                $result.Version = $setup.Version
                $result.Edition = $setup.Edition
            }
        }
        else
        {
            _Log "Registry: Instanz '$instanceUpper' nicht gefunden." 'INFO'
        }

        # --- 2. Dienst-Pruefung ---
        $svcName = if ($instanceUpper -eq 'MSSQLSERVER') {
            'MSSQLSERVER'
        } else {
            "MSSQL`$$instanceUpper"
        }
        $result.ServiceName = $svcName

        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc)
        {
            $result.ServiceState = $svc.Status.ToString()
            _Log "Dienst '$svcName': $($svc.Status)"
            # Dienst vorhanden zaehlt auch als installiert (auch ohne Registry-Eintrag)
            if (-not $result.IsInstalled)
            {
                $result.IsInstalled = $true
                _Log "Dienst vorhanden aber kein Registry-Eintrag - markiere als installiert." 'WARNING'
            }
        }
        else
        {
            $result.ServiceState = 'NotFound'
            _Log "Dienst '$svcName' nicht gefunden."
        }

        # --- Zusammenfassung ---
        if ($result.IsInstalled)
        {
            $result.Status  = 'Installed'
            $versionStr     = if ($result.Version)  { " v$($result.Version)" }  else { '' }
            $editionStr     = if ($result.Edition)  { " ($($result.Edition))" } else { '' }
            $result.Message = "SQL Server '$instanceUpper'$versionStr$editionStr ist installiert. " +
                              "Dienst '$svcName': $($result.ServiceState)"
        }
        else
        {
            $result.Status  = 'NotInstalled'
            $result.Message = "SQL Server '$instanceUpper' ist NICHT installiert."
        }

        _Log $result.Message
    }
    catch
    {
        $result.Status  = 'Error'
        $result.Message = "Fehler bei der Instanzpruefung: $($_.Exception.Message)"
        _Log $result.Message 'ERROR'
        Write-Error $result.Message
    }

    return $result
}
