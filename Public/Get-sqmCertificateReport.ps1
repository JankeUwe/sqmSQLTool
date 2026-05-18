<#
.SYNOPSIS
    Erstellt einen vollstaendigen Bericht ueber SQL Server-Zertifikate und deren Ablaufdaten.

.DESCRIPTION
    Prueft auf einer oder mehreren Instanzen alle sicherheitsrelevanten Zertifikate:

    MASTER KEY
      - Prueft ob ein Database Master Key in master vorhanden ist (Voraussetzung fuer Zertifikate)
      - Prueft ob der DMK mit dem Service Master Key verschluesselt ist (wichtig fuer automatischen Start)

    INSTANZ-ZERTIFIKATE (sys.certificates in master)
      - AlwaysOn-Endpoint-Zertifikate (Hadr_endpoint)
      - Service Broker-Zertifikate
      - Backup-Verschluesselungszertifikate
      - Alle weiteren Zertifikate in master

    TDE-ZERTIFIKATE (Transparent Data Encryption)
      - Pro verschluesselter Datenbank: welches Zertifikat, Ablaufdatum, Encryption State

    DATENBANK-ZERTIFIKATE
      - Zertifikate in User-Datenbanken (z.B. fuer Column Encryption, Signing)

    PRO ZERTIFIKAT:
      - Name, Typ, Aussteller, Subject
      - Ablaufdatum mit Ampel-Status (OK / Warning / Critical / Expired)
      - Verbleibende Tage bis Ablauf
      - Verwendungszweck (AlwaysOn / TDE / ServiceBroker / Backup / UserDefined)
      - Ob der private Schluessel vorhanden und verschluesselt ist
      - Thumbprint

    Die Ergebnisse werden als TXT-Bericht und CSV im konfigurierten OutputPath gespeichert.
    Zusaetzlich wird eine gefilterte CSV nur mit ablaufenden/abgelaufenen Zertifikaten erzeugt.

.PARAMETER SqlInstance
    SQL Server-Instanz(en). Pipeline-faehig. Standard: aktueller Computername.

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER WarningThresholdDays
    Zertifikate die in weniger als diesem Wert ablaufen, erhalten Status 'Warning'. Standard: 90.

.PARAMETER CriticalThresholdDays
    Zertifikate die in weniger als diesem Wert ablaufen, erhalten Status 'Critical'. Standard: 30.

.PARAMETER IncludeUserDatabases
    Auch Zertifikate in User-Datenbanken einbeziehen. Standard: $false.

.PARAMETER OutputPath
    Ausgabeverzeichnis fuer Berichtsdateien. Standard: aus Modulkonfiguration.

.PARAMETER ContinueOnError
    Bei Fehler auf einer Instanz fortfahren statt abzubrechen.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.EXAMPLE
    Get-sqmCertificateReport

.EXAMPLE
    Get-sqmCertificateReport -SqlInstance "SQL01","SQL02" -WarningThresholdDays 180

.EXAMPLE
    # Nur ablaufende Zertifikate anzeigen
    Get-sqmCertificateReport -SqlInstance "SQL01" |
        Select-Object -ExpandProperty Certificates |
        Where-Object { $_.ExpiryStatus -ne 'OK' } |
        Select-Object SqlInstance, DatabaseName, CertificateName, ExpiryDate, DaysRemaining, ExpiryStatus, Purpose

.EXAMPLE
    # Pipeline ueber mehrere Instanzen
    'SQL01','SQL02','SQL03' | Get-sqmCertificateReport -OutputPath "D:\Reports\Certs"

.NOTES
    Erfordert: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath, Copy-sqmToCentralPath
    Benoetigt VIEW ANY DEFINITION und VIEW SERVER STATE.
    TDE-Pruefung liest sys.dm_database_encryption_keys (benoetigt VIEW DATABASE STATE).
    AlwaysOn-Endpoint-Erkennung ueber sys.database_mirroring_endpoints und sys.service_broker_endpoints.
#>
function Get-sqmCertificateReport
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true, Position = 0)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[int]$WarningThresholdDays = 90,
		[Parameter(Mandatory = $false)]
		[int]$CriticalThresholdDays = 30,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeUserDatabases,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)
	
	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$allInstanceResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		$now = Get-Date
		
		if (-not $script:dbatoolsAvailable)
		{
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}
		
		if (-not $OutputPath)
		{
			$OutputPath = Get-sqmDefaultOutputPath
		}
		
		Invoke-sqmLogging -Message "Starte $functionName (Warning=${WarningThresholdDays}d, Critical=${CriticalThresholdDays}d)" -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		foreach ($instance in $SqlInstance)
		{
			Invoke-sqmLogging -Message "Verarbeite Instanz: $instance" -FunctionName $functionName -Level "INFO"
			
			try
			{
				$connParams = @{
					SqlInstance   = $instance
					SqlCredential = $SqlCredential
				}

				$server = Connect-DbaInstance @connParams -ErrorAction Stop
				$certificates = [System.Collections.Generic.List[PSCustomObject]]::new()
				
				# -------------------------------------------------------------------
				# 1. Database Master Key Status in master pruefen
				# -------------------------------------------------------------------
				$dmkQuery = @"
SELECT
    name,
    is_master_key_encrypted_by_server,
    modify_date
FROM sys.symmetric_keys
WHERE name = '##MS_DatabaseMasterKey##'
"@
				$dmkResult = Invoke-DbaQuery @connParams -Database 'master' -Query $dmkQuery -ErrorAction SilentlyContinue
				$hasDmk = ($null -ne $dmkResult)
				$dmkEncryptedBySmk = if ($hasDmk) { [bool]$dmkResult.is_master_key_encrypted_by_server }
				else { $false }
				
				Invoke-sqmLogging -Message "DMK in master: $hasDmk, mit SMK verschluesselt: $dmkEncryptedBySmk" -FunctionName $functionName -Level "INFO"
				
				# -------------------------------------------------------------------
				# 2. AlwaysOn- und Mirroring-Endpoint-Typ ermitteln
				#    (um Zertifikate spaeter korrekt als 'AlwaysOn' zu markieren)
				# -------------------------------------------------------------------
				$endpointCertQuery = @"
SELECT
    e.name        AS EndpointName,
    e.type_desc   AS EndpointType,
    c.name        AS CertificateName
FROM sys.endpoints e
INNER JOIN sys.database_mirroring_endpoints dme ON e.endpoint_id = dme.endpoint_id
INNER JOIN sys.certificates c ON dme.certificate_id = c.certificate_id
UNION ALL
SELECT
    e.name,
    'SERVICE_BROKER',
    c.name
FROM sys.endpoints e
INNER JOIN sys.service_broker_endpoints sbe ON e.endpoint_id = sbe.endpoint_id
INNER JOIN sys.certificates c ON sbe.certificate_id = c.certificate_id
"@
				$endpointCerts = @{ }
				try
				{
					$epResult = Invoke-DbaQuery @connParams -Database 'master' -Query $endpointCertQuery -ErrorAction SilentlyContinue
					foreach ($ep in $epResult)
					{
						$endpointCerts[$ep.CertificateName] = $ep.EndpointType
					}
				}
				catch { <# Endpoint-Abfrage optional - bei Fehler ignorieren #> }
				
				# -------------------------------------------------------------------
				# 3. TDE-Zertifikate ermitteln
				# -------------------------------------------------------------------
				$tdeCertNames = @{ }
				$tdeQuery = @"
SELECT
    d.name              AS DatabaseName,
    c.name              AS CertificateName,
    dek.encryption_state,
    CASE dek.encryption_state
        WHEN 0 THEN 'No encryption'
        WHEN 1 THEN 'Unencrypted'
        WHEN 2 THEN 'Encryption in progress'
        WHEN 3 THEN 'Encrypted'
        WHEN 4 THEN 'Key change in progress'
        WHEN 5 THEN 'Decryption in progress'
        ELSE    'Unknown'
    END                 AS EncryptionStateDesc
FROM sys.dm_database_encryption_keys dek
INNER JOIN sys.databases d    ON dek.database_id = d.database_id
INNER JOIN sys.certificates c ON dek.encryptor_thumbprint = c.thumbprint
"@
				try
				{
					$tdeResult = Invoke-DbaQuery @connParams -Database 'master' -Query $tdeQuery -ErrorAction SilentlyContinue
					foreach ($tde in $tdeResult)
					{
						$tdeCertNames[$tde.CertificateName] = [PSCustomObject]@{
							DatabaseName = $tde.DatabaseName
							EncryptionState = $tde.EncryptionStateDesc
						}
					}
				}
				catch { <# TDE optional - VIEW DATABASE STATE fehlt moeglicherweise #> }
				
				# -------------------------------------------------------------------
				# 4. Alle Zertifikate in master abfragen
				# -------------------------------------------------------------------
				$certQuery = @"
SELECT
    c.name                                           AS CertificateName,
    c.certificate_id,
    c.pvt_key_encryption_type_desc                  AS PrivateKeyEncryption,
    c.is_active_for_begin_dialog                    AS IsActiveForDialog,
    c.issuer_name                                   AS IssuerName,
    c.subject                                       AS Subject,
    c.start_date                                    AS ValidFrom,
    c.expiry_date                                   AS ExpiryDate,
    c.thumbprint                                    AS Thumbprint,
    c.attested_by                                   AS AttestedBy,
    HAS_PERMS_BY_NAME(c.name, 'CERTIFICATE', 'CONTROL') AS HasControl,
    -- Privater Schluessel vorhanden?
    CASE WHEN c.pvt_key_encryption_type_desc <> 'NO_PRIVATE_KEY' THEN 1 ELSE 0 END AS HasPrivateKey
FROM sys.certificates c
ORDER BY c.expiry_date ASC
"@
				$masterCerts = Invoke-DbaQuery @connParams -Database 'master' -Query $certQuery -ErrorAction Stop
				
				foreach ($cert in $masterCerts)
				{
					$purpose = Get-sqmCertPurpose -CertName $cert.CertificateName `
												  -EndpointCerts $endpointCerts -TdeCerts $tdeCertNames
					
					$certObj = New-sqmCertObject `
												 -Cert $cert `
												 -SqlInstance $instance `
												 -DatabaseName 'master' `
												 -Purpose $purpose `
												 -Now $now `
												 -WarningDays $WarningThresholdDays `
												 -CriticalDays $CriticalThresholdDays `
												 -TdeCerts $tdeCertNames
					
					$certificates.Add($certObj)
				}
				
				Invoke-sqmLogging -Message "$($masterCerts.Count) Zertifikat(e) in master gefunden." -FunctionName $functionName -Level "INFO"
				
				# -------------------------------------------------------------------
				# 5. Optional: Zertifikate in User-Datenbanken
				# -------------------------------------------------------------------
				if ($IncludeUserDatabases)
				{
					$userDbs = Get-DbaDatabase @connParams -ExcludeSystem -ErrorAction SilentlyContinue |
					Where-Object { $_.IsAccessible -and $_.Status -eq 'Normal' }
					
					foreach ($db in $userDbs)
					{
						try
						{
							$dbCerts = Invoke-DbaQuery @connParams -Database $db.Name -Query $certQuery -ErrorAction SilentlyContinue
							foreach ($cert in $dbCerts)
							{
								$certObj = New-sqmCertObject `
															 -Cert $cert `
															 -SqlInstance $instance `
															 -DatabaseName $db.Name `
															 -Purpose 'UserDefined' `
															 -Now $now `
															 -WarningDays $WarningThresholdDays `
															 -CriticalDays $CriticalThresholdDays `
															 -TdeCerts @{ }
								
								$certificates.Add($certObj)
							}
						}
						catch
						{
							Invoke-sqmLogging -Message "Zertifikate in DB '$($db.Name)' konnten nicht gelesen werden: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
						}
					}
				}
				
				# -------------------------------------------------------------------
				# 6. Statusauswertung
				# -------------------------------------------------------------------
				$expiredCount = @($certificates | Where-Object { $_.ExpiryStatus -eq 'Expired' }).Count
				$criticalCount = @($certificates | Where-Object { $_.ExpiryStatus -eq 'Critical' }).Count
				$warningCount = @($certificates | Where-Object { $_.ExpiryStatus -eq 'Warning' }).Count
				$overallStatus = if ($expiredCount -gt 0) { 'Critical' }
				elseif ($criticalCount -gt 0) { 'Critical' }
				elseif ($warningCount -gt 0) { 'Warning' }
				else { 'OK' }
				
				$instanceResult = [PSCustomObject]@{
					SqlInstance	      = $instance
					CaptureTime	      = $now
					OverallStatus	  = $overallStatus
					TotalCertificates = $certificates.Count
					ExpiredCount	  = $expiredCount
					CriticalCount	  = $criticalCount
					WarningCount	  = $warningCount
					HasDatabaseMasterKey = $hasDmk
					DmkEncryptedBySmk = $dmkEncryptedBySmk
					Certificates	  = $certificates
				}
				
				$allInstanceResults.Add($instanceResult)
				
				# -------------------------------------------------------------------
				# 7. Berichte schreiben
				# -------------------------------------------------------------------
				if ($PSCmdlet.ShouldProcess($instance, "Zertifikatsbericht schreiben"))
				{
					Write-sqmCertReport `
										-InstanceResult $instanceResult `
										-OutputPath $OutputPath `
										-FunctionName $functionName
				}
				
				$msg = "[$instance] $($certificates.Count) Zertifikat(e): $expiredCount abgelaufen, $criticalCount kritisch, $warningCount Warnung."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"
				Write-Verbose $msg
			}
			catch
			{
				$errMsg = "Fehler auf Instanz '$instance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { Write-Error $errMsg; return }
				Write-Warning $errMsg
			}
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allInstanceResults.Count) Instanz(en) verarbeitet." -FunctionName $functionName -Level "INFO"
		return $allInstanceResults
	}
}

# ---------------------------------------------------------------------------
# Private Hilfsfunktionen
# ---------------------------------------------------------------------------

function Get-sqmCertPurpose
{
	param (
		[string]$CertName,
		[hashtable]$EndpointCerts,
		[hashtable]$TdeCerts
	)
	if ($EndpointCerts.ContainsKey($CertName))
	{
		$epType = $EndpointCerts[$CertName]
		return if ($epType -like '*MIRROR*' -or $epType -like '*DATABASE_MIRRORING*') { 'AlwaysOn' }
		else { 'ServiceBroker' }
	}
	if ($TdeCerts.ContainsKey($CertName)) { return 'TDE' }
	if ($CertName -like '*backup*') { return 'Backup' }
	if ($CertName -like '*hadr*' -or
		$CertName -like '*mirror*' -or
		$CertName -like '*ag_*' -or
		$CertName -like '*alwayson*') { return 'AlwaysOn' }
	if ($CertName -like '*broker*' -or
		$CertName -like '*ssb*') { return 'ServiceBroker' }
	return 'UserDefined'
}

function New-sqmCertObject
{
	param (
		$Cert,
		[string]$SqlInstance,
		[string]$DatabaseName,
		[string]$Purpose,
		[datetime]$Now,
		[int]$WarningDays,
		[int]$CriticalDays,
		[hashtable]$TdeCerts
	)
	
	$daysRemaining = if ($Cert.ExpiryDate)
	{
		[int]($Cert.ExpiryDate - $Now).TotalDays
	}
	else { $null }
	
	$expiryStatus = if ($null -eq $daysRemaining) { 'NoExpiry' }
	elseif ($daysRemaining -lt 0) { 'Expired' }
	elseif ($daysRemaining -lt $CriticalDays) { 'Critical' }
	elseif ($daysRemaining -lt $WarningDays) { 'Warning' }
	else { 'OK' }
	
	# TDE-Zusatzinfo
	$tdeDatabase = $null
	$tdeEncryptionState = $null
	if ($Purpose -eq 'TDE' -and $TdeCerts.ContainsKey($Cert.CertificateName))
	{
		$tdeInfo = $TdeCerts[$Cert.CertificateName]
		$tdeDatabase = $tdeInfo.DatabaseName
		$tdeEncryptionState = $tdeInfo.EncryptionState
	}
	
	return [PSCustomObject]@{
		SqlInstance	    = $SqlInstance
		DatabaseName    = $DatabaseName
		CertificateName = $Cert.CertificateName
		Purpose		    = $Purpose
		Subject		    = $Cert.Subject
		IssuerName	    = $Cert.IssuerName
		ValidFrom	    = $Cert.ValidFrom
		ExpiryDate	    = $Cert.ExpiryDate
		DaysRemaining   = $daysRemaining
		ExpiryStatus    = $expiryStatus
		HasPrivateKey   = [bool]$Cert.HasPrivateKey
		PrivateKeyEncryption = $Cert.PrivateKeyEncryption
		Thumbprint	    = if ($Cert.Thumbprint)
		{
			[System.BitConverter]::ToString($Cert.Thumbprint).Replace('-', '')
		} else { $null }
		TdeDatabaseName = $tdeDatabase
		TdeEncryptionState = $tdeEncryptionState
		IsActiveForDialog = [bool]$Cert.IsActiveForDialog
	}
}

function Write-sqmCertReport
{
	param (
		[PSCustomObject]$InstanceResult,
		[string]$OutputPath,
		[string]$FunctionName
	)
	
	if (-not (Test-Path $OutputPath))
	{
		New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
	}
	
	$instance = $InstanceResult.SqlInstance -replace '\\', '_'
	$datestamp = Get-Date -Format 'yyyyMMdd_HHmsqm'
	$baseName = "CertReport_${instance}_${datestamp}"
	
	# --- TXT-Bericht ---
	$txtFile = Join-Path $OutputPath "${baseName}.txt"
	$lines = [System.Collections.Generic.List[string]]::new()
	
	$lines.Add("=" * 80)
	$lines.Add("  SQL SERVER ZERTIFIKATSBERICHT")
	$lines.Add("  Instanz    : $($InstanceResult.SqlInstance)")
	$lines.Add("  Erstellt   : $($InstanceResult.CaptureTime.ToString('yyyy-MM-dd HH:mm:ss'))")
	$lines.Add("  Status     : $($InstanceResult.OverallStatus)")
	$lines.Add("=" * 80)
	$lines.Add("")
	$lines.Add("ZUSAMMENFASSUNG")
	$lines.Add("-" * 40)
	$lines.Add("  Zertifikate gesamt : $($InstanceResult.TotalCertificates)")
	$lines.Add("  Abgelaufen         : $($InstanceResult.ExpiredCount)")
	$lines.Add("  Kritisch (<30 Tage): $($InstanceResult.CriticalCount)")
	$lines.Add("  Warnung  (<90 Tage): $($InstanceResult.WarningCount)")
	$lines.Add("  Database Master Key: $(if ($InstanceResult.HasDatabaseMasterKey) { 'Vorhanden' }
			else { 'FEHLT' })")
	$lines.Add("  DMK mit SMK verschl: $(if ($InstanceResult.DmkEncryptedBySmk) { 'Ja (automatischer Start moeglich)' }
			else { 'Nein (manuelles oeffnen erforderlich)' })")
	$lines.Add("")
	
	# Gruppiert nach Status
	foreach ($status in @('Expired', 'Critical', 'Warning', 'OK', 'NoExpiry'))
	{
		$group = $InstanceResult.Certificates | Where-Object { $_.ExpiryStatus -eq $status }
		if (-not $group) { continue }
		
		$lines.Add("ZERTIFIKATE - STATUS: $status")
		$lines.Add("-" * 40)
		
		foreach ($c in ($group | Sort-Object DaysRemaining))
		{
			$lines.Add("  Name       : $($c.CertificateName)")
			$lines.Add("  Zweck      : $($c.Purpose)")
			$lines.Add("  Datenbank  : $($c.DatabaseName)")
			$lines.Add("  Gueltig von : $(if ($c.ValidFrom) { $c.ValidFrom.ToString('yyyy-MM-dd') }
					else { 'n/a' })")
			$lines.Add("  Laeuft ab   : $(if ($c.ExpiryDate) { $c.ExpiryDate.ToString('yyyy-MM-dd') }
					else { 'kein Ablaufdatum' })")
			$lines.Add("  Verbleibend: $(if ($null -ne $c.DaysRemaining) { "$($c.DaysRemaining) Tage" }
					else { 'n/a' })")
			$lines.Add("  Subject    : $($c.Subject)")
			$lines.Add("  Aussteller : $($c.IssuerName)")
			$lines.Add("  Priv. Key  : $(if ($c.HasPrivateKey) { "Ja ($($c.PrivateKeyEncryption))" }
					else { 'Nein - ACHTUNG: kein Restore/Recovery moeglich' })")
			$lines.Add("  Thumbprint : $($c.Thumbprint)")
			if ($c.TdeDatabaseName)
			{
				$lines.Add("  TDE-Db     : $($c.TdeDatabaseName) [$($c.TdeEncryptionState)]")
			}
			$lines.Add("")
		}
	}
	
	$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
	Invoke-sqmLogging -Message "TXT-Bericht: $txtFile" -FunctionName $FunctionName -Level "INFO"
	
	# --- Vollstaendige CSV ---
	$csvFile = Join-Path $OutputPath "${baseName}.csv"
	$InstanceResult.Certificates |
	Select-Object SqlInstance, DatabaseName, CertificateName, Purpose, ExpiryStatus,
				  DaysRemaining, ExpiryDate, ValidFrom, Subject, IssuerName,
				  HasPrivateKey, PrivateKeyEncryption, Thumbprint,
				  TdeDatabaseName, TdeEncryptionState |
	Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
	Invoke-sqmLogging -Message "CSV-Bericht: $csvFile" -FunctionName $FunctionName -Level "INFO"
	
	# --- Gefilterte CSV: nur Probleme ---
	$alertCerts = $InstanceResult.Certificates |
	Where-Object { $_.ExpiryStatus -in @('Expired', 'Critical', 'Warning') }
	if ($alertCerts)
	{
		$alertCsvFile = Join-Path $OutputPath "${baseName}_ALERTS.csv"
		$alertCerts |
		Select-Object SqlInstance, DatabaseName, CertificateName, Purpose, ExpiryStatus,
					  DaysRemaining, ExpiryDate, HasPrivateKey, TdeDatabaseName |
		Export-Csv -Path $alertCsvFile -NoTypeInformation -Encoding UTF8 -Force
		Invoke-sqmLogging -Message "Alert-CSV: $alertCsvFile" -FunctionName $FunctionName -Level "WARNING"
	}
	
	# Zentrale Kopie
	Copy-sqmToCentralPath -Path @($txtFile, $csvFile)
}