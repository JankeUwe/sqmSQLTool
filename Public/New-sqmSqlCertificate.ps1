<#
.SYNOPSIS
    Creates a new self-signed SQL Server certificate as a renewal of an existing one.

.DESCRIPTION
    Reads all relevant properties of the existing certificate (Subject, purpose,
    endpoint binding, TDE binding) and creates a new self-signed certificate directly
    in SQL Server using CREATE CERTIFICATE.

    Process:
      1. Read existing certificate and determine its purpose
      2. Back up old certificate as .cer + private key as .pvk (BackupPath)
      3. Create new certificate with same subject and new expiry date
      4. Back up the NEW certificate as .cer + .pvk into the same folder (the .cer is the
         public key for AlwaysOn/Broker partners, .cer + .pvk are needed for TDE on secondaries
         and for any restore)
      5. Only if requested, bind based on purpose:
           AlwaysOn  -> ALTER ENDPOINT ... FOR DATABASE_MIRRORING (AUTHENTICATION = CERTIFICATE <new>)
           Broker    -> ALTER ENDPOINT ... FOR SERVICE_BROKER (AUTHENTICATION = CERTIFICATE <new>)
           TDE       -> ALTER DATABASE ENCRYPTION KEY ENCRYPTION BY SERVER CERTIFICATE <new>
      6. Write a renewal protocol as TXT (Subject, thumbprint old/new, bindings, next steps)

    The old certificate is neither renamed nor dropped: SQL Server has no way to rename a
    certificate, and it is still needed until all bindings are switched (and, for TDE, to
    restore older backups). Drop it manually after verification.

    ORDER FOR ALWAYSON: the partner replicas must know the NEW public key before this replica's
    endpoint is switched, otherwise they reject the connection and the AG disconnects. Run
    without -BindEndpoint, import the new .cer on every partner
    (Install-sqmCertificate -Purpose AlwaysOn -AuthorizationUser ...), then switch the endpoint.
    TDE IN AN AG: the new certificate (.cer + .pvk) must exist on every secondary before -BindTde.

    BackupPath is a path on the SQL Server host: BACKUP CERTIFICATE is executed by the service.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER CertificateName
    Name of the certificate to renew (exact name from sys.certificates).

.PARAMETER Database
    Database where the certificate resides. Default: master.

.PARAMETER NewCertificateName
    Name of the new certificate. Default: <OldName>_<Year> (e.g. AG_CERT_2027).

.PARAMETER ValidityYears
    Validity period of the new certificate in years. Default: 5.

.PARAMETER BackupPath
    Path for backing up the old certificate (.cer and .pvk).
    Default: from module configuration (OutputPath).

.PARAMETER BackupEncryptionPassword
    Password for encrypting the exported private keys (.pvk) of the old and the new certificate.
    Required when the old certificate has a private key.

.PARAMETER RenameOldCertificate
    Obsolete, has no effect. SQL Server cannot rename certificates; the old certificate
    always stays under its name until you drop it. Kept for compatibility of existing scripts.

.PARAMETER BindEndpoint
    Switch the endpoint (AlwaysOn: DATABASE_MIRRORING, Broker: SERVICE_BROKER) to the new
    certificate immediately. Default: $false. For AlwaysOn only after the partners have the
    new public key.

.PARAMETER BindTde
    Re-encrypt the database encryption keys of the TDE databases with the new certificate.
    Default: $false. In an availability group only after the new certificate exists on all
    secondaries.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    # Simple renewal without automatic binding
    New-sqmSqlCertificate -SqlInstance "SQL01" -CertificateName "AG_CERT" -BackupEncryptionPassword (Read-Host -AsSecureString)

.EXAMPLE
    # With automatic endpoint binding and 10-year validity
    New-sqmSqlCertificate -SqlInstance "SQL01" -CertificateName "AG_CERT" `
        -ValidityYears 10 -BindEndpoint `
        -BackupEncryptionPassword (Read-Host -AsSecureString "Backup-Passwort")

.EXAMPLE
    # Renew TDE certificate
    New-sqmSqlCertificate -SqlInstance "SQL01" -CertificateName "TDE_PROD" `
        -BindTde -BackupEncryptionPassword (Read-Host -AsSecureString "Backup-Passwort")

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath, Copy-sqmToCentralPath
    Requires: sysadmin on the instance.
    AlwaysOn: After renewal the new certificate (.cer) must be imported on all partner replicas
    with the endpoint login's user as owner (Install-sqmCertificate -AuthorizationUser).
    TDE: Key rotation runs online, the database remains available.
#>
function New-sqmSqlCertificate
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[string]$CertificateName,
		[Parameter(Mandatory = $false)]
		[string]$Database = 'master',
		[Parameter(Mandatory = $false)]
		[string]$NewCertificateName,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 20)]
		[int]$ValidityYears = 5,
		[Parameter(Mandatory = $false)]
		[string]$BackupPath,
		[Parameter(Mandatory = $false)]
		[System.Security.SecureString]$BackupEncryptionPassword,
		[Parameter(Mandatory = $false)]
		[bool]$RenameOldCertificate = $true,
		[Parameter(Mandatory = $false)]
		[switch]$BindEndpoint,
		[Parameter(Mandatory = $false)]
		[switch]$BindTde,
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
		
		if (-not $script:dbatoolsAvailable)
		{
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}
		
		if (-not $BackupPath) { $BackupPath = Get-sqmDefaultOutputPath }
		
		Invoke-sqmLogging -Message ("Starte " + $functionName + ": Zertifikat '$CertificateName' auf $SqlInstance") -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		try
		{
			$connParams = @{
				SqlInstance   = $SqlInstance
				SqlCredential = $SqlCredential
				Database	  = $Database
			}
			# Abfragen in master: eigene Kopie - @connParams enthaelt bereits -Database, ein zusaetzliches
			# -Database bricht unter Windows PowerShell 5.1 mit 'Parameter mehrfach angegeben' ab
			$masterParams = $connParams.Clone()
			$masterParams['Database'] = 'master'
			
			# -------------------------------------------------------------------
			# 1. Bestehendes Zertifikat lesen
			# -------------------------------------------------------------------
			$existingCertQuery = @"
SELECT
    c.name                          AS CertificateName,
    c.certificate_id,
    c.subject,
    c.start_date,
    c.expiry_date,
    c.issuer_name,
    c.thumbprint,
    c.pvt_key_encryption_type_desc  AS PrivateKeyEncryption,
    CASE WHEN c.pvt_key_encryption_type_desc <> 'NO_PRIVATE_KEY' THEN 1 ELSE 0 END AS HasPrivateKey
FROM sys.certificates c
WHERE c.name = '$($CertificateName -replace "'", "''")'
"@
			$existingCert = Invoke-DbaQuery @connParams -Query $existingCertQuery -ErrorAction Stop
			
			if (-not $existingCert)
			{
				throw "Zertifikat '$CertificateName' nicht gefunden in Datenbank '$Database' auf '$SqlInstance'."
			}
			
			# -------------------------------------------------------------------
			# 2. Endpoint-Bindung ermitteln
			# -------------------------------------------------------------------
			$endpointQuery = @"
SELECT
    e.name          AS EndpointName,
    e.endpoint_id,
    e.type_desc     AS EndpointType,
    e.protocol_desc AS Protocol
FROM sys.endpoints e
INNER JOIN sys.database_mirroring_endpoints dme ON e.endpoint_id = dme.endpoint_id
INNER JOIN sys.certificates c ON dme.certificate_id = c.certificate_id
WHERE c.name = '$($CertificateName -replace "'", "''")'
UNION ALL
SELECT e.name, e.endpoint_id, 'SERVICE_BROKER', e.protocol_desc
FROM sys.endpoints e
INNER JOIN sys.service_broker_endpoints sbe ON e.endpoint_id = sbe.endpoint_id
INNER JOIN sys.certificates c ON sbe.certificate_id = c.certificate_id
WHERE c.name = '$($CertificateName -replace "'", "''")'
"@
			$boundEndpoint = Invoke-DbaQuery @masterParams -Query $endpointQuery -ErrorAction SilentlyContinue
			
			# -------------------------------------------------------------------
			# 3. TDE-Bindung ermitteln
			# -------------------------------------------------------------------
			$tdeQuery = @"
SELECT d.name AS DatabaseName, dek.encryption_state
FROM sys.dm_database_encryption_keys dek
INNER JOIN sys.databases d    ON dek.database_id = d.database_id
INNER JOIN sys.certificates c ON dek.encryptor_thumbprint = c.thumbprint
WHERE c.name = '$($CertificateName -replace "'", "''")'
"@
			$tdeDatabases = Invoke-DbaQuery @masterParams -Query $tdeQuery -ErrorAction SilentlyContinue
			
			# -------------------------------------------------------------------
			# 4. Neuen Zertifikatsnamen festlegen
			# -------------------------------------------------------------------
			if (-not $NewCertificateName)
			{
				$NewCertificateName = "$($CertificateName)_$((Get-Date).AddYears($ValidityYears).Year)"
			}
			
			$expiryDate = (Get-Date).AddYears($ValidityYears).ToString('yyyyMMdd')
			$subject = if ($existingCert.subject) { $existingCert.subject }
			else { "CN=$NewCertificateName" }
			$datestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
			$oldRename = "$($CertificateName)_OLD_$(Get-Date -Format 'yyyyMMdd')"
			
			# Passwort-Pruefung: Private Key vorhanden ? Passwort fuer Backup Pflicht
			if ($existingCert.HasPrivateKey -and -not $BackupEncryptionPassword)
			{
				throw "Das Zertifikat '$CertificateName' hat einen Private Key. Bitte -BackupEncryptionPassword angeben fuer die Backup-Verschluesselung."
			}
			
			# ShouldProcess-Bestaetigung
			$action = "Zertifikat '$CertificateName' erneuern ? '$NewCertificateName' (gueltig bis $expiryDate)"
			if (-not $PSCmdlet.ShouldProcess($SqlInstance, $action))
			{
				Invoke-sqmLogging -Message "Abgebrochen durch ShouldProcess." -FunctionName $functionName -Level "INFO"
				return $null
			}
			
			# -------------------------------------------------------------------
			# 5. Backup-Verzeichnis vorbereiten
			# -------------------------------------------------------------------
			$certBackupDir = Join-Path $BackupPath "CertBackup_$(($SqlInstance -replace '\\', '_'))_$datestamp"
			if (-not (Test-Path $certBackupDir)) { New-Item -ItemType Directory -Path $certBackupDir -Force | Out-Null }
			
			# -------------------------------------------------------------------
			# 6. Altes Zertifikat sichern (.cer + optional .pvk)
			# -------------------------------------------------------------------
			# BACKUP CERTIFICATE schreibt der SQL Server-Dienst - Verzeichnis auch serverseitig anlegen
			$certBackupDirSql = $certBackupDir -replace "'", "''"
			Invoke-DbaQuery @masterParams -Query "EXEC master.dbo.xp_create_subdir N'$certBackupDirSql';" -ErrorAction Stop

			# Passwort als Klartext fuer T-SQL (nur im Speicher, nicht geloggt)
			$plainPwd = $null
			if ($BackupEncryptionPassword)
			{
				$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($BackupEncryptionPassword)
				$plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) -replace "'", "''"
				[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
			}

			try
			{
				$cerFile = Join-Path $certBackupDir "$($CertificateName)_OLD.cer"
				$pvkFile = $null
				$backupSql = "BACKUP CERTIFICATE [$CertificateName] TO FILE = N'$($cerFile -replace "'", "''")'"
				if ($existingCert.HasPrivateKey)
				{
					$pvkFile = Join-Path $certBackupDir "$($CertificateName)_OLD.pvk"
					$backupSql += " WITH PRIVATE KEY (FILE = N'$($pvkFile -replace "'", "''")', ENCRYPTION BY PASSWORD = N'$plainPwd')"
				}
				Invoke-DbaQuery @connParams -Query "$backupSql;" -ErrorAction Stop
				Invoke-sqmLogging -Message "Backup des alten Zertifikats: $cerFile" -FunctionName $functionName -Level "INFO"

				# -------------------------------------------------------------------
				# 7. Neues Zertifikat erstellen
				# -------------------------------------------------------------------
				$createSql = @"
CREATE CERTIFICATE [$NewCertificateName]
WITH SUBJECT = N'$($subject -replace "'", "''")',
     EXPIRY_DATE = N'$expiryDate';
"@
				Invoke-DbaQuery @connParams -Query $createSql -ErrorAction Stop
				Invoke-sqmLogging -Message "Neues Zertifikat '$NewCertificateName' erstellt (gueltig bis $expiryDate)." -FunctionName $functionName -Level "INFO"

				# Neues Zertifikat sofort sichern: .cer = Public Key fuer AG-/Broker-Partner,
				# .cer + .pvk fuer TDE auf Secondaries und fuer jedes spaetere Restore
				$newCerFile = Join-Path $certBackupDir "$($NewCertificateName).cer"
				$newPvkFile = $null
				$newBackupSql = "BACKUP CERTIFICATE [$NewCertificateName] TO FILE = N'$($newCerFile -replace "'", "''")'"
				if ($plainPwd)
				{
					$newPvkFile = Join-Path $certBackupDir "$($NewCertificateName).pvk"
					$newBackupSql += " WITH PRIVATE KEY (FILE = N'$($newPvkFile -replace "'", "''")', ENCRYPTION BY PASSWORD = N'$plainPwd')"
				}
				Invoke-DbaQuery @connParams -Query "$newBackupSql;" -ErrorAction Stop
				Invoke-sqmLogging -Message "Backup des neuen Zertifikats: $newCerFile" -FunctionName $functionName -Level "INFO"
				if (-not $newPvkFile)
				{
					Write-Warning "Private Key des neuen Zertifikats '$NewCertificateName' NICHT gesichert (kein -BackupEncryptionPassword). Sofort nachholen: BACKUP CERTIFICATE ... WITH PRIVATE KEY."
				}
			}
			finally
			{
				$plainPwd = $null # Sofort aus Speicher entfernen
			}

			# Neues Zertifikat lesen fuer Rueckgabeobjekt
			$newCert = Invoke-DbaQuery @connParams -Query ($existingCertQuery -replace [regex]::Escape("'$($CertificateName -replace "'", "''")'"), "'$($NewCertificateName -replace "'", "''")'") -ErrorAction SilentlyContinue

			# -------------------------------------------------------------------
			# 8. Optional: Endpoint-Bindung aktualisieren
			# -------------------------------------------------------------------
			$endpointBound = $false
			if ($BindEndpoint -and $boundEndpoint)
			{
				foreach ($ep in $boundEndpoint)
				{
					$epClause = if ($ep.EndpointType -eq 'SERVICE_BROKER') { 'SERVICE_BROKER' }
					else { 'DATABASE_MIRRORING' }
					$alterEndpointSql = @"
ALTER ENDPOINT [$($ep.EndpointName)]
    FOR $epClause (AUTHENTICATION = CERTIFICATE [$NewCertificateName]);
"@
					Invoke-DbaQuery @masterParams -Query $alterEndpointSql -ErrorAction Stop
					Invoke-sqmLogging -Message "Endpoint '$($ep.EndpointName)' auf neues Zertifikat '$NewCertificateName' umgestellt." -FunctionName $functionName -Level "INFO"
					$endpointBound = $true
				}
			}

			# -------------------------------------------------------------------
			# 9. Optional: TDE-Bindung aktualisieren
			# -------------------------------------------------------------------
			$tdeBound = $false
			if ($BindTde -and $tdeDatabases)
			{
				foreach ($tdeDb in $tdeDatabases)
				{
					$alterTdeSql = @"
USE [$($tdeDb.DatabaseName)];
ALTER DATABASE ENCRYPTION KEY
    ENCRYPTION BY SERVER CERTIFICATE [$NewCertificateName];
"@
					Invoke-DbaQuery @masterParams -Query $alterTdeSql -ErrorAction Stop
					Invoke-sqmLogging -Message "TDE fuer '$($tdeDb.DatabaseName)' auf '$NewCertificateName' umgestellt." -FunctionName $functionName -Level "INFO"
					$tdeBound = $true
				}
			}

			# -------------------------------------------------------------------
			# 10. Altes Zertifikat bleibt bestehen
			# -------------------------------------------------------------------
			# SQL Server kennt kein Umbenennen von Zertifikaten (-RenameOldCertificate ist wirkungslos).
			# Das alte Zertifikat wird erst nach Verifikation manuell geloescht (siehe Protokoll).
			Invoke-sqmLogging -Message "Altes Zertifikat '$CertificateName' bleibt bestehen. Nach Verifikation manuell loeschen." -FunctionName $functionName -Level "INFO"

			# -------------------------------------------------------------------
			# 11. Bestelldatenblatt schreiben
			# -------------------------------------------------------------------
			$sheetFile = Join-Path $certBackupDir "Erneuerungsprotokoll_${CertificateName}_${datestamp}.txt"
			$lines = [System.Collections.Generic.List[string]]::new()
			
			$lines.Add("=" * 70)
			$lines.Add("  ZERTIFIKAT-ERNEUERUNGSPROTOKOLL")
			$lines.Add("  Erstellt  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
			$lines.Add("  Instanz   : $SqlInstance")
			$lines.Add("  Datenbank : $Database")
			$lines.Add("=" * 70)
			$lines.Add("")
			$lines.Add("ALTES ZERTIFIKAT")
			$lines.Add("-" * 40)
			$lines.Add("  Name        : $CertificateName")
			$lines.Add("  Subject     : $($existingCert.subject)")
			$lines.Add("  Aussteller  : $($existingCert.issuer_name)")
			$lines.Add("  Gueltig von  : $(if ($existingCert.start_date) { $existingCert.start_date.ToString('yyyy-MM-dd') }
					else { 'n/a' })")
			$lines.Add("  Abgelaufen  : $(if ($existingCert.expiry_date) { $existingCert.expiry_date.ToString('yyyy-MM-dd') }
					else { 'n/a' })")
			$lines.Add("  Thumbprint  : $([System.BitConverter]::ToString($existingCert.thumbprint).Replace('-', ''))")
			$lines.Add("  Private Key : $(if ($existingCert.HasPrivateKey) { $existingCert.PrivateKeyEncryption }
					else { 'Kein Private Key' })")
			$lines.Add("  Backup .cer : $cerFile")
			if ($pvkFile) { $lines.Add("  Backup .pvk : $pvkFile") }
			$lines.Add("")
			$lines.Add("NEUES ZERTIFIKAT")
			$lines.Add("-" * 40)
			$lines.Add("  Name        : $NewCertificateName")
			$lines.Add("  Subject     : $subject")
			$lines.Add("  Gueltig bis  : $expiryDate")
			if ($newCert)
			{
				$lines.Add("  Thumbprint  : $([System.BitConverter]::ToString($newCert.thumbprint).Replace('-', ''))")
			}
			$lines.Add("  Backup .cer : $newCerFile")
			if ($newPvkFile) { $lines.Add("  Backup .pvk : $newPvkFile") }
			$lines.Add("")
			
			if ($boundEndpoint)
			{
				$lines.Add("ENDPOINT-BINDUNG")
				$lines.Add("-" * 40)
				foreach ($ep in $boundEndpoint)
				{
					$lines.Add("  Endpoint    : $($ep.EndpointName) [$($ep.EndpointType)]")
					$lines.Add("  Umgestellt  : $(if ($endpointBound) { 'JA - automatisch' }
							else { 'NEIN - manuell erforderlich' })")
					if (-not $endpointBound)
					{
						$lines.Add("  T-SQL       : ALTER ENDPOINT [$($ep.EndpointName)] FOR $(if ($ep.EndpointType -eq 'SERVICE_BROKER') { 'SERVICE_BROKER' } else { 'DATABASE_MIRRORING' })")
						$lines.Add("                (AUTHENTICATION = CERTIFICATE [$NewCertificateName]);")
					}
				}
				$lines.Add("")
				$lines.Add("  *** WICHTIG FueR ALWAYSON / SERVICE BROKER ***")
				$lines.Add("  Jeder Partner muss den neuen Public Key kennen, BEVOR der Endpoint umgestellt wird:")
				$lines.Add("  1. Gesicherter Public Key: $newCerFile")
				$lines.Add("  2. Auf jedem Partner importieren, Besitzer = Benutzer des Endpoint-Logins:")
				$lines.Add("     Install-sqmCertificate -SqlInstance <Partner> -CertFile <Pfad>\$NewCertificateName.cer \")
				$lines.Add("         -CertificateName '$NewCertificateName' -Purpose AlwaysOn -AuthorizationUser <Benutzer>")
				$lines.Add("  3. Erst dann hier den Endpoint umstellen (T-SQL oben) und den AG-Status pruefen.")
				$lines.Add("")
			}
			
			if ($tdeDatabases)
			{
				$lines.Add("TDE-BINDUNG")
				$lines.Add("-" * 40)
				foreach ($tdeDb in $tdeDatabases)
				{
					$lines.Add("  Datenbank   : $($tdeDb.DatabaseName)")
					$lines.Add("  Umgestellt  : $(if ($tdeBound) { 'JA - automatisch (online, kein Downtime)' }
							else { 'NEIN - manuell erforderlich' })")
					if (-not $tdeBound)
					{
						$lines.Add("  T-SQL       : USE [$($tdeDb.DatabaseName)];")
						$lines.Add("                ALTER DATABASE ENCRYPTION KEY")
						$lines.Add("                ENCRYPTION BY SERVER CERTIFICATE [$NewCertificateName];")
					}
				}
				$lines.Add("")
				$lines.Add("  *** WICHTIG FueR TDE ***")
				if ($newPvkFile)
				{
					$lines.Add("  Neues Zertifikat inkl. Private Key gesichert: $newPvkFile")
					$lines.Add("  Sicherung getrennt vom Server aufbewahren, Passwort separat ablegen.")
				}
				else
				{
					$lines.Add("  Private Key des neuen Zertifikats ist NICHT gesichert - sofort nachholen:")
					$lines.Add("  BACKUP CERTIFICATE [$NewCertificateName] TO FILE = N'<Pfad>.cer'")
					$lines.Add("  WITH PRIVATE KEY (FILE = N'<Pfad>.pvk', ENCRYPTION BY PASSWORD = N'<Passwort>');")
				}
				$lines.Add("  AlwaysOn: .cer + .pvk VOR dem Umstellen auf allen Secondaries importieren")
				$lines.Add("  (Install-sqmCertificate -CertFile ... -PrivateKeyFile ... -CertPassword ...).")
				$lines.Add("  Altes Zertifikat behalten, solange Backups existieren, die damit verschluesselt sind.")
				$lines.Add("")
			}
			
			$lines.Add("NaeCHSTE SCHRITTE")
			$lines.Add("-" * 40)
			$lines.Add("  1. Funktionalitaet des neuen Zertifikats verifizieren")
			$lines.Add("  2. AlwaysOn-Replikation / TDE-Status pruefen")
			$lines.Add("  3. Altes Zertifikat '$CertificateName' nach Verifikation loeschen:")
			$lines.Add("     DROP CERTIFICATE [$CertificateName];")
			$lines.Add("  4. Backup-Dateien sicher archivieren: $certBackupDir")
			$lines.Add("  5. Zertifikat-Ablaufdatum im Monitoring aktualisieren")
			$lines.Add("")
			$lines.Add("GESICHERTE DATEIEN")
			$lines.Add("-" * 40)
			$lines.Add("  Verzeichnis : $certBackupDir")
			$lines.Add("  Zertifikat  : $cerFile")
			if ($pvkFile) { $lines.Add("  Private Key : $pvkFile (mit Passwort verschluesselt)") }
			$lines.Add("  Neu .cer    : $newCerFile")
			if ($newPvkFile) { $lines.Add("  Neu .pvk    : $newPvkFile (mit Passwort verschluesselt)") }
			$lines.Add("  Protokoll   : $sheetFile")
			
			$lines | Out-File -FilePath $sheetFile -Encoding UTF8 -Force
			Invoke-sqmLogging -Message "Erneuerungsprotokoll: $sheetFile" -FunctionName $functionName -Level "INFO"
			
			Copy-sqmToCentralPath -Path @($sheetFile, $cerFile)
			
			# -------------------------------------------------------------------
			# 12. Rueckgabeobjekt
			# -------------------------------------------------------------------
			$result = [PSCustomObject]@{
				SqlInstance	       = $SqlInstance
				Database		   = $Database
				OldCertificateName = $CertificateName
				NewCertificateName = $NewCertificateName
				NewExpiryDate	   = (Get-Date).AddYears($ValidityYears)
				NewThumbprint	   = if ($newCert) { [System.BitConverter]::ToString($newCert.thumbprint).Replace('-', '') } else { $null }
				EndpointBound	   = $endpointBound
				TdeBound		   = $tdeBound
				BackupDirectory    = $certBackupDir
				CerBackupFile	   = $cerFile
				PvkBackupFile	   = $pvkFile
				NewCerBackupFile   = $newCerFile
				NewPvkBackupFile   = $newPvkFile
				ProtocolFile	   = $sheetFile
				Success		       = $true
			}
			
			Write-Host "Zertifikat '$NewCertificateName' erfolgreich erstellt." -ForegroundColor Green
			Write-Host "Protokoll  : $sheetFile" -ForegroundColor Cyan
			Write-Host "Backup-Dir : $certBackupDir" -ForegroundColor Cyan
			
			return $result
		}
		catch
		{
			$errMsg = "Fehler bei Zertifikat-Erneuerung: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
			return [PSCustomObject]@{ Success = $false; ErrorMessage = $errMsg }
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
	}
}