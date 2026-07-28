<#
.SYNOPSIS
    Ermittelt verlaesslich, ob eine Datenbank Mitglied einer AlwaysOn-Availability-Group ist.

.DESCRIPTION
    Beantwortet DREI Zustaende statt zwei, und genau darin liegt der Zweck dieser Funktion:

        - Die Instanz hat AlwaysOn gar nicht aktiviert            -> HadrEnabled = $false
        - Die Instanz hat AlwaysOn, die Datenbank ist kein Mitglied -> IsAgDatabase = $false
        - Die Frage konnte nicht beantwortet werden                -> Ausnahme

    Der bisherige Weg ueber Get-DbaAgDatabase mit -ErrorAction SilentlyContinue konnte den dritten
    Zustand nicht ausdruecken: fehlende Rechte (VIEW ANY DEFINITION / VIEW SERVER STATE), eine
    stolpernde SMO-Enumeration oder eine Verbindung zur falschen Instanz lieferten allesamt ein
    leeres Ergebnis, das vom aufrufenden Code als "ist in keiner AG" gelesen wurde. Invoke-sqm-
    RestoreDatabase ist daraufhin direkt auf ALTER DATABASE und RESTORE losgegangen, die SQL Server
    beide mit "is involved in a database mirroring session or an availability group" abgelehnt hat -
    nachdem bereits mehrere Schritte gelaufen waren. Ein stiller Fallback auf die harmlos aussehende
    Variante, an der genau die Sicherung haengt, die den Restore ueberhaupt erst moeglich macht.

    Gefragt wird direkt in den Katalogsichten, nicht ueber SMO:

        sys.availability_databases_cluster    Mitgliedschaft, clusterweit von JEDEM Replikat lesbar
        sys.dm_hadr_availability_replica_states  aktuelle Rollenverteilung, fuer die Primary

    Beide sind reine Metadaten und kosten nichts. Die Mitgliedschaftsfrage ist die harte: schlaegt
    sie fehl, wirft diese Funktion. Die Primary-Ermittlung ist die weiche: sie braucht zusaetzlich
    VIEW SERVER STATE, und wenn die fehlt, bleibt PrimaryReplica leer, ohne dass die Mitgliedschafts-
    aussage dadurch wertlos wuerde - der Aufrufer kann die Primary dann anderweitig bestimmen.

.PARAMETER SqlInstance
    Instanz, ueber die gefragt wird. Die AG-Katalogsichten sind clusterweit, es muss also nicht die
    Primary sein.

.PARAMETER Database
    Name der Datenbank.

.PARAMETER SqlCredential
    Optionales PSCredential.

.OUTPUTS
    PSCustomObject mit HadrEnabled, IsAgDatabase, AvailabilityGroupName, PrimaryReplica.

.NOTES
    Private Hilfsfunktion fuer Invoke-sqmRestoreDatabase - nicht exportiert.
#>
function Get-sqmDatabaseAgMembership
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $true)]
		[string]$Database,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	$functionName = $MyInvocation.MyCommand.Name

	$connParams = @{ SqlInstance = $SqlInstance; Database = 'master' }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	# ---- 1. Ist AlwaysOn auf dieser Instanz ueberhaupt aktiviert? ----
	# Auf einer Instanz ohne HADR sind die AG-Sichten zwar vorhanden, aber leer. Diese Abfrage
	# trennt "keine AG vorhanden" sauber von "AG vorhanden, Datenbank nicht drin" und laeuft auf
	# jeder Edition.
	try
	{
		$hadrRow = Invoke-DbaQuery @connParams -Query "SELECT CONVERT(int, ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0)) AS HadrEnabled" `
										 -As PSObject -EnableException
		$hadrEnabled = [int]$hadrRow.HadrEnabled -eq 1
	}
	catch
	{
		throw "AlwaysOn-Status von '$SqlInstance' konnte nicht ermittelt werden: $($_.Exception.Message)"
	}

	if (-not $hadrEnabled)
	{
		Invoke-sqmLogging -Message "Instanz '$SqlInstance' hat AlwaysOn nicht aktiviert - '$Database' kann keine AG-Datenbank sein." `
						  -FunctionName $functionName -Level 'INFO'
		return [PSCustomObject]@{
			HadrEnabled			  = $false
			IsAgDatabase		  = $false
			AvailabilityGroupName = $null
			PrimaryReplica		  = $null
		}
	}

	# ---- 2. Mitgliedschaft - die harte Frage, ein Fehler hier darf NICHT als "nein" durchgehen ----
	$dbLiteral = $Database.Replace("'", "''")
	$membershipQuery = @"
SELECT TOP (1) ag.name AS AvailabilityGroupName
FROM sys.availability_databases_cluster adc
JOIN sys.availability_groups ag ON ag.group_id = adc.group_id
WHERE adc.database_name = N'$dbLiteral';
"@

	try
	{
		$agRow = @(Invoke-DbaQuery @connParams -Query $membershipQuery -As PSObject -EnableException) | Select-Object -First 1
	}
	catch
	{
		throw "AG-Mitgliedschaft von '$Database' auf '$SqlInstance' konnte nicht ermittelt werden - der Vorgang wird abgebrochen, " +
		"statt die Datenbank faelschlich als Standalone zu behandeln (ein RESTORE gegen eine AG-Datenbank wird von SQL Server " +
		"abgelehnt). Fehlen ggf. die Rechte VIEW ANY DEFINITION? Ursache: $($_.Exception.Message)"
	}

	if (-not $agRow -or [string]::IsNullOrWhiteSpace($agRow.AvailabilityGroupName))
	{
		Invoke-sqmLogging -Message "'$Database' ist auf '$SqlInstance' in keiner Availability Group (Instanz hat AlwaysOn aktiviert)." `
						  -FunctionName $functionName -Level 'INFO'
		return [PSCustomObject]@{
			HadrEnabled			  = $true
			IsAgDatabase		  = $false
			AvailabilityGroupName = $null
			PrimaryReplica		  = $null
		}
	}

	$agName = [string]$agRow.AvailabilityGroupName

	# ---- 3. Primary - die weiche Frage, braucht zusaetzlich VIEW SERVER STATE ----
	# Faellt sie aus, bleibt die Mitgliedschaftsaussage oben trotzdem gueltig; der Aufrufer
	# ermittelt die Primary dann ueber das SMO-AG-Objekt.
	$primaryReplica = $null
	$primaryQuery = @"
SELECT TOP (1) ar.replica_server_name AS PrimaryReplica
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ar.replica_id = ars.replica_id
JOIN sys.availability_groups ag   ON ag.group_id   = ars.group_id
WHERE ag.name = N'$($agName.Replace("'", "''"))' AND ars.role = 1;
"@
	try
	{
		$primaryRow = @(Invoke-DbaQuery @connParams -Query $primaryQuery -As PSObject -EnableException) | Select-Object -First 1
		if ($primaryRow) { $primaryReplica = [string]$primaryRow.PrimaryReplica }
	}
	catch
	{
		Invoke-sqmLogging -Message "Primary-Replikat der AG '$agName' konnte nicht ermittelt werden (fehlt VIEW SERVER STATE?), die Mitgliedschaft steht aber fest: $($_.Exception.Message)" `
						  -FunctionName $functionName -Level 'WARNING'
	}

	Invoke-sqmLogging -Message "'$Database' ist Mitglied der Availability Group '$agName'$(if ($primaryReplica) { ", Primary: '$primaryReplica'" })." `
					  -FunctionName $functionName -Level 'INFO'

	return [PSCustomObject]@{
		HadrEnabled			  = $true
		IsAgDatabase		  = $true
		AvailabilityGroupName = $agName
		PrimaryReplica		  = $primaryReplica
	}
}
