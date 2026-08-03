<#
.SYNOPSIS
    Gleicht den in SQL Server registrierten Servernamen (@@SERVERNAME) an den aktuellen
    Windows-Hostnamen/FQDN an, nachdem der Rechner umbenannt wurde.

.DESCRIPTION
    Nach einer Windows-Umbenennung (Hostname- oder FQDN-Aenderung, z. B. nach VM-Klon oder
    Rechenzentrums-Umzug) meldet Windows sofort den neuen Namen (SERVERPROPERTY('MachineName')),
    waehrend SQL Server den ALTEN Namen weiter in sys.servers als "lokalen Server" fuehrt
    (SERVERPROPERTY('ServerName') / @@SERVERNAME). Dieser Drift faellt oft erst auf, wenn
    Replikation, Linked-Server-Loopbacks, SSRS oder Zertifikate mit dem falschen Namen
    fehlschlagen.

    Diese Funktion:
    - Ermittelt den erwarteten Namen aus MachineName (+ \InstanceName bei Named Instance) und
      vergleicht ihn mit dem registrierten @@SERVERNAME.
    - Bricht bei Abweichung NICHT blind mit sp_dropserver/sp_addserver durch, sondern prueft
      vorher Failover-Cluster-Mitgliedschaft (IsClustered), AlwaysOn-AG-Mitgliedschaft
      (sys.availability_replicas) und Replikationsrollen (sys.databases: is_distributor,
      is_published, is_subscribed, is_merge_published). In all diesen Faellen haengen andere
      Objekte am alten Namen (replica_server_name, Distributor-Registrierung, Publikationen) -
      ein reines sp_addserver wuerde die Instanz technisch umbenennen, aber diese Referenzen
      brechen. Ohne -Force wird deshalb abgebrochen (Status 'Blocked').
    - Fuehrt bei Freigabe sp_dropserver (alter Name) + sp_addserver (neuer Name, local) aus.
    - Weist darauf hin, dass ein Neustart des SQL Server-Dienstes noetig ist, bis @@SERVERNAME
      den neuen Wert zurueckgibt. Die Funktion startet den Dienst NICHT automatisch neu.

.PARAMETER SqlInstance
    Name der SQL-Instanz. Standard: lokaler Computername ($env:COMPUTERNAME).

.PARAMETER SqlCredential
    Optionale SQL-Credentials (Standard: Windows-Authentifizierung).

.PARAMETER Force
    Ignoriert die Guard-Checks (Cluster/AG/Replikation) und erzwingt sp_dropserver/sp_addserver
    trotzdem. Nur verwenden, wenn die betroffenen Objekte (AG-Replika, Publikationen, ...) bereits
    separat behandelt wurden oder bewusst in Kauf genommen werden.

.PARAMETER EnableException
    Wirft Exceptions statt sie nur im Ergebnisobjekt zu melden.

.OUTPUTS
    [PSCustomObject] mit:
        SqlInstance          : Instanzname (wie uebergeben)
        RegisteredServerName : @@SERVERNAME vor der Aenderung
        ExpectedServerName   : Aus MachineName/InstanceName berechneter Soll-Name
        IsClustered          : SERVERPROPERTY('IsClustered') = 1?
        Status               : AlreadyCorrect | Changed | Blocked | WhatIf | Error
        RestartRequired      : $true, wenn ein Dienst-Neustart fuer @@SERVERNAME noch aussteht
        Message              : Detailmeldung

.EXAMPLE
    Repair-sqmServerName

    Prueft die lokale Default-Instanz und korrigiert @@SERVERNAME bei Bedarf (mit Guard-Checks).

.EXAMPLE
    Repair-sqmServerName -SqlInstance 'SQL01\INST01' -WhatIf

    Zeigt nur an, welche sp_dropserver/sp_addserver-Schritte ausgefuehrt wuerden.

.EXAMPLE
    Repair-sqmServerName -SqlInstance 'SQL01' -Force -Confirm:$false

    Erzwingt die Umbenennung auch wenn AG-/Replikations-/Cluster-Referenzen erkannt wurden.

.NOTES
    Nach der Aenderung ist ein Neustart des SQL Server-Dienstes erforderlich, damit @@SERVERNAME
    den neuen Wert liefert. sys.servers wird sofort aktualisiert, die Session-Funktion
    @@SERVERNAME/SERVERPROPERTY('ServerName') jedoch erst nach dem Neustart.
    Bei Failover-Cluster-Instanzen (FCI) und AlwaysOn wird der Netzwerkname ueber die
    Cluster-/AG-Konfiguration verwaltet - dort ist i. d. R. keine manuelle Korrektur noetig bzw.
    diese Funktion ist der falsche Weg (siehe Guard-Check IsClustered).
#>
function Repair-sqmServerName
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name

	function _Log { param([string]$Msg, [string]$Level = 'INFO')
		Write-Verbose "[$functionName] $Msg"
		try { Invoke-sqmLogging -Message $Msg -FunctionName $functionName -Level $Level } catch { }
	}

	$result = [PSCustomObject]@{
		SqlInstance		     = $SqlInstance
		RegisteredServerName = $null
		ExpectedServerName   = $null
		IsClustered		     = $null
		Status			     = 'Error'
		RestartRequired	     = $false
		Message			     = $null
	}

	try
	{
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			throw "dbatools-Modul nicht gefunden."
		}

		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

		_Log "Starte $functionName auf $SqlInstance."
		Connect-DbaInstance @connParams -ErrorAction Stop | Out-Null

		# --- Registrierten vs. erwarteten Servernamen ermitteln ---
		$props = Invoke-DbaQuery @connParams -Query @"
SELECT
    CAST(SERVERPROPERTY('ServerName')   AS sysname) AS RegisteredServerName,
    CAST(SERVERPROPERTY('MachineName')  AS sysname) AS MachineName,
    CAST(SERVERPROPERTY('InstanceName') AS sysname) AS InstanceName,
    CAST(SERVERPROPERTY('IsClustered')  AS int)     AS IsClustered
"@ -ErrorAction Stop

		$registeredName = $props.RegisteredServerName
		$expectedName = if ([string]::IsNullOrEmpty($props.InstanceName)) { $props.MachineName }
		else { "$($props.MachineName)\$($props.InstanceName)" }

		$result.RegisteredServerName = $registeredName
		$result.ExpectedServerName = $expectedName
		$result.IsClustered = [bool]$props.IsClustered

		_Log "Registriert: '$registeredName' | Erwartet (MachineName/InstanceName): '$expectedName' | IsClustered: $($result.IsClustered)"

		if ($registeredName -eq $expectedName)
		{
			$result.Status = 'AlreadyCorrect'
			$result.Message = "@@SERVERNAME ('$registeredName') stimmt bereits mit dem Windows-Namen ueberein - keine Aenderung noetig."
			_Log $result.Message 'INFO'
			Write-Host "  OK: $($result.Message)" -ForegroundColor Green
			return $result
		}

		# --- Guard-Checks (ueberspringbar mit -Force) ---
		if (-not $Force)
		{
			if ($result.IsClustered)
			{
				$result.Status = 'Blocked'
				$result.Message = "Instanz ist Teil eines Failover-Clusters (IsClustered=1). Der Netzwerkname wird " +
				"ueber die Cluster-Konfiguration verwaltet - sp_dropserver/sp_addserver ist hier i. d. R. der " +
				"falsche Weg. Mit -Force erzwingen, falls die Umbenennung dennoch beabsichtigt ist."
				_Log $result.Message 'WARNING'
				Write-Warning $result.Message
				return $result
			}

			$agCount = Invoke-DbaQuery @connParams -Query "SELECT COUNT(*) AS Cnt FROM sys.availability_replicas WHERE replica_server_name = @@SERVERNAME" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Cnt
			if ($agCount -gt 0)
			{
				$agNames = Invoke-DbaQuery @connParams -Query "SELECT ag.name FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id WHERE ar.replica_server_name = @@SERVERNAME" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty name
				$result.Status = 'Blocked'
				$result.Message = "AlwaysOn Availability Group erkannt ($($agNames -join ', ')). replica_server_name " +
				"referenziert den alten Namen - eine Umbenennung erfordert das Entfernen/Neuanlegen des Replikas " +
				"in der AG. Mit -Force erzwingen, wenn das bereits separat behandelt wurde."
				_Log $result.Message 'WARNING'
				Write-Warning $result.Message
				return $result
			}

			$replRoles = Invoke-DbaQuery @connParams -Query "SELECT name FROM sys.databases WHERE is_distributor = 1 OR is_published = 1 OR is_subscribed = 1 OR is_merge_published = 1" -ErrorAction SilentlyContinue
			if ($replRoles)
			{
				$result.Status = 'Blocked'
				$result.Message = "Replikationsrolle erkannt (Distributor/Publisher/Subscriber bei: $(($replRoles | Select-Object -ExpandProperty name) -join ', ')). " +
				"Publikationen/Subscriptions referenzieren den alten Servernamen. Mit -Force erzwingen, wenn " +
				"die Replikation bereits separat behandelt wurde."
				_Log $result.Message 'WARNING'
				Write-Warning $result.Message
				return $result
			}
		}

		$repairAction = "sp_dropserver '$registeredName' + sp_addserver '$expectedName', local"
		if ($PSCmdlet.ShouldProcess($SqlInstance, $repairAction))
		{
			$oldEsc = $registeredName -replace "'", "''"
			$newEsc = $expectedName -replace "'", "''"

			_Log "Fuehre sp_dropserver '$registeredName' aus." 'INFO'
			Invoke-DbaQuery @connParams -Database 'master' -Query "EXEC sp_dropserver @server = N'$oldEsc';" -ErrorAction Stop | Out-Null

			try
			{
				_Log "Fuehre sp_addserver '$expectedName' (local) aus." 'INFO'
				Invoke-DbaQuery @connParams -Database 'master' -Query "EXEC sp_addserver @server = N'$newEsc', local;" -ErrorAction Stop | Out-Null
			}
			catch
			{
				# Kritisch: sp_dropserver ist bereits durch - die Instanz hat jetzt KEINEN lokalen
				# Servereintrag mehr. Klar melden statt still zu verschlucken.
				$result.Status = 'Error'
				$result.Message = "sp_dropserver('$registeredName') war erfolgreich, sp_addserver('$expectedName') " +
				"ist fehlgeschlagen: $($_.Exception.Message). Die Instanz hat aktuell KEINEN lokalen Server-Eintrag " +
				"mehr - manuell mit 'EXEC sp_addserver N''$newEsc'', local;' nachziehen."
				_Log $result.Message 'ERROR'
				Write-Error $result.Message
				if ($EnableException) { throw }
				return $result
			}

			$result.Status = 'Changed'
			$result.RestartRequired = $true
			$result.Message = "Servername von '$registeredName' auf '$expectedName' korrigiert. " +
			"Neustart des SQL Server-Dienstes erforderlich, bis @@SERVERNAME den neuen Wert zurueckgibt."
			_Log $result.Message 'INFO'
			Write-Host "  OK: $($result.Message)" -ForegroundColor Green
		}
		else
		{
			$result.Status = 'WhatIf'
			$result.Message = "WhatIf: '$registeredName' -> '$expectedName' ($repairAction), keine Aenderung vorgenommen."
			_Log $result.Message 'INFO'
			Write-Host "  [WhatIf] $($result.Message)" -ForegroundColor Yellow
		}
	}
	catch
	{
		$result.Status = 'Error'
		$result.Message = "Fehler in $functionName : $($_.Exception.Message)"
		_Log $result.Message 'ERROR'
		Write-Error $result.Message
		if ($EnableException) { throw }
	}

	return $result
}
