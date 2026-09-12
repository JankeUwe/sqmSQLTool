<#
.SYNOPSIS
Adds one or more databases to an Always On availability group (AutoSeed).

.DESCRIPTION
- Checks whether the database is already in an AG.
- Sets recovery mode to Full (if necessary).
- Recognizes TDE-encrypted databases and checks their preconditions BEFORE any change.
- Optionally distributes the TDE certificate to every secondary replica (-SyncTdeCertificate).
- Drops existing databases on all secondary replicas.
- Adds the database to the AG using Automatic Seeding.
- With -All, databases are added sequentially to avoid load spikes.

TDE handling:
Automatic Seeding of an encrypted database requires SQL Server 2019 (major version 15) or
higher on EVERY replica, and the certificate protecting the database encryption key must
already exist on each secondary. Both are verified before the database is touched. Below
SQL 2019 the database is skipped with status "TdeUnsupportedVersion" - there the only
route is backup/restore, not seeding.

.PARAMETER SqlInstance
Primary SQL instance (default: computer name).

.PARAMETER SqlCredential
Credentials.

.PARAMETER AvailabilityGroup
Name of the target availability group (mandatory).

.PARAMETER Database
Name or array of databases. Ignored when -All is set.

.PARAMETER All
Add all user databases that are not yet in an AG.

.PARAMETER SyncTdeCertificate
For TDE-encrypted databases: export the encryptor certificate from the primary and create it
on every secondary that does not have it yet (matched by thumbprint, not by name).
Without this switch such a database is skipped with status "TdeCertificateMissing".
Requires -TdeCertificateBackupPath and -TdeCertificatePassword.

.PARAMETER TdeCertificateBackupPath
Directory for the temporary certificate export (.cer + .pvk).
BACKUP CERTIFICATE writes it under the primary's SQL service account and CREATE CERTIFICATE
reads it under the secondary's service account, so this must be a share both accounts can
reach - a local path only works on a single-machine lab setup.

.PARAMETER TdeCertificatePassword
Password protecting the exported private key (.pvk). The same password is used to decrypt it
on the secondaries.

.PARAMETER TdeMasterKeyPassword
Password used to create the database master key in master on a secondary that has none yet.
Defaults to -TdeCertificatePassword when omitted.

.PARAMETER KeepTdeCertificateBackup
Keep the exported .cer/.pvk files. Default: they are deleted after distribution, because the
.pvk carries the private key of the TDE certificate.

.PARAMETER EnableException
Allow exceptions to pass through.

.PARAMETER Confirm
Request confirmation.

.PARAMETER WhatIf
Test only (no changes).

.EXAMPLE
Add-sqmDatabaseToAG -AvailabilityGroup "AG1" -Database "SalesDB"

.EXAMPLE
Add-sqmDatabaseToAG -AvailabilityGroup "AG1" -All

.EXAMPLE
# TDE-encrypted database including certificate distribution to all secondaries
Add-sqmDatabaseToAG -AvailabilityGroup "AG1" -Database "PayrollDB" -SyncTdeCertificate `
    -TdeCertificateBackupPath "\\fileserver\sqlcerts$" `
    -TdeCertificatePassword (Read-Host -AsSecureString "Private-Key-Kennwort")

.EXAMPLE
# Dry run: reports per database whether TDE preconditions are met, changes nothing
Add-sqmDatabaseToAG -AvailabilityGroup "AG1" -All -WhatIf

.NOTES
Requires Automatic Seeding on all replicas (can be enabled separately with Invoke-sqmSqlAlwaysOnAutoseeding).
TDE distribution needs the module dbatools and CONTROL on the certificate on the primary plus
CREATE CERTIFICATE on every secondary.
#>
function Add-sqmDatabaseToAG
	
{
	[CmdletBinding(DefaultParameterSetName = 'Specific', SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[string]$AvailabilityGroup,
		[Parameter(Mandatory = $false, ParameterSetName = 'Specific')]
		[string[]]$Database,
		[Parameter(Mandatory = $false, ParameterSetName = 'All')]
		[switch]$All,
		[Parameter(Mandatory = $false)]
		[switch]$SyncTdeCertificate,
		[Parameter(Mandatory = $false)]
		[string]$TdeCertificateBackupPath,
		[Parameter(Mandatory = $false)]
		[System.Security.SecureString]$TdeCertificatePassword,
		[Parameter(Mandatory = $false)]
		[System.Security.SecureString]$TdeMasterKeyPassword,
		[Parameter(Mandatory = $false)]
		[switch]$KeepTdeCertificateBackup,
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
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			throw "dbatools-Modul nicht gefunden."
		}

		# SecureString -> Klartext. Der BSTR wird explizit genullt und freigegeben; ein einfaches
		# PtrToStringAuto ohne finally laesst das Kennwort im Prozessspeicher stehen.
		$toPlain = {
			param ([System.Security.SecureString]$Secure)
			if (-not $Secure) { return '' }
			$ptr = [System.IntPtr]::Zero
			try
			{
				$ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
				return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)
			}
			finally
			{
				if ($ptr -ne [System.IntPtr]::Zero)
				{
					[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
				}
			}
		}

		# Automatic Seeding einer TDE-verschluesselten Datenbank gibt es erst ab SQL Server 2019.
		# Davor ist der einzige Weg Backup/Restore mit vorher verteiltem Zertifikat.
		$tdeMinVersionMajor = 15
		$versionCache = @{ }
		$exportedCerts = @{ }
		$exportedFiles = [System.Collections.Generic.List[string]]::new()
		$certPwPlain = ''
		$mkPwPlain = ''

		# Parameterkombination pruefen, bevor irgendetwas angefasst wird
		if ($SyncTdeCertificate)
		{
			if ([string]::IsNullOrWhiteSpace($TdeCertificateBackupPath))
			{
				throw "-SyncTdeCertificate benoetigt -TdeCertificateBackupPath. BACKUP CERTIFICATE schreibt unter dem SQL-Dienstkonto des Primary, CREATE CERTIFICATE liest unter dem des Secondary - der Pfad muss also fuer beide erreichbar sein."
			}
			if (-not $TdeCertificatePassword)
			{
				throw "-SyncTdeCertificate benoetigt -TdeCertificatePassword. Damit wird der exportierte Private Key verschluesselt und auf dem Secondary wieder entschluesselt."
			}
			if (-not (Test-Path -Path $TdeCertificateBackupPath -PathType Container))
			{
				throw "TdeCertificateBackupPath '$TdeCertificateBackupPath' nicht gefunden oder kein Verzeichnis."
			}
			$certPwPlain = & $toPlain $TdeCertificatePassword
			if ($TdeMasterKeyPassword)
			{
				$mkPwPlain = & $toPlain $TdeMasterKeyPassword
			}
			else
			{
				$mkPwPlain = $certPwPlain
				Invoke-sqmLogging -Message "Kein -TdeMasterKeyPassword angegeben. Ein fehlender Datenbank-Hauptschluessel auf einem Secondary wird mit dem Kennwort aus -TdeCertificatePassword angelegt." -FunctionName $functionName -Level "INFO"
			}
		}
		elseif ($PSBoundParameters.ContainsKey('TdeCertificateBackupPath') -or $PSBoundParameters.ContainsKey('TdeCertificatePassword') -or $PSBoundParameters.ContainsKey('TdeMasterKeyPassword'))
		{
			Invoke-sqmLogging -Message "TDE-Parameter angegeben, aber -SyncTdeCertificate fehlt. Es werden keine Zertifikate verteilt." -FunctionName $functionName -Level "WARNING"
		}

		# Hauptversion einer Instanz, pro Instanz nur einmal ermittelt
		$getVersionMajor = {
			param ([string]$Instance)
			if (-not $versionCache.ContainsKey($Instance))
			{
				$srv = Connect-DbaInstance -SqlInstance $Instance -SqlCredential $SqlCredential -ErrorAction Stop
				$versionCache[$Instance] = [int]$srv.VersionMajor
			}
			return $versionCache[$Instance]
		}

		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance, AG: $AvailabilityGroup" -FunctionName $functionName -Level "INFO"
		$results = @()
	}
	
	process
	{
		try
		{
			# Verfuegbarkeitsgruppe validieren und sekundaere Replikate ermitteln
			$ag = Get-DbaAvailabilityGroup -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $AvailabilityGroup -ErrorAction Stop
			if (-not $ag) { throw "AG '$AvailabilityGroup' nicht gefunden." }
			$replicas = Get-DbaAgReplica -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $AvailabilityGroup
			$secondaryInstances = $replicas | Where-Object { $_.Role -eq 'Secondary' } | Select-Object -ExpandProperty Name

			# TDE-Zustand aller Benutzerdatenbanken einmal einlesen. Ist der Encryptor ein
			# Zertifikat, liefert der LEFT JOIN dessen Namen; bei einem asymmetrischen Schluessel
			# (EKM/Key Vault) bleibt er NULL - das ist genau die Unterscheidung, die spaeter zaehlt.
			$tdeMap = @{ }
			try
			{
				$tdeQuery = @"
SELECT d.name AS DatabaseName,
       dek.encryption_state AS EncryptionState,
       c.name AS CertificateName,
       CONVERT(varchar(100), dek.encryptor_thumbprint, 1) AS EncryptorThumbprint
FROM sys.dm_database_encryption_keys dek
INNER JOIN sys.databases d ON d.database_id = dek.database_id
LEFT JOIN sys.certificates c ON c.thumbprint = dek.encryptor_thumbprint
WHERE d.database_id > 4
"@
				$tdeRows = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database 'master' -Query $tdeQuery -EnableException
				foreach ($row in $tdeRows) { $tdeMap[$row.DatabaseName] = $row }
				if ($tdeMap.Count -gt 0)
				{
					Invoke-sqmLogging -Message "TDE-verschluesselt auf '$SqlInstance': $($tdeMap.Keys -join ', ')" -FunctionName $functionName -Level "INFO"
				}
			}
			catch
			{
				# Ohne VIEW SERVER STATE bleibt die Sicht leer. Das darf den Lauf nicht abbrechen,
				# muss aber sichtbar sein: unerkannte TDE-Datenbanken scheitern sonst erst beim Seeding.
				Invoke-sqmLogging -Message "TDE-Status nicht ermittelbar ($($_.Exception.Message)). Alle Datenbanken werden als unverschluesselt behandelt - bei einer verschluesselten Datenbank schlaegt das Seeding dann auf dem Secondary fehl." -FunctionName $functionName -Level "WARNING"
			}

			# Prueft und schafft die Voraussetzungen fuer eine TDE-Datenbank. Laeuft VOR jeder
			# Aenderung, weil der spaetere Ablauf die Datenbank auf den Secondaries loescht -
			# ein Abbruch danach liesse die Secondaries ohne Kopie zurueck.
			$prepareTde = {
				param ([string]$DbName, [PSObject]$TdeInfo)

				# Invoke-DbaQuery liefert DataRows: ein NULL aus dem LEFT JOIN kommt als [DBNull]
				# an, nicht als $null. Ungeprueft an [string]::IsNullOrWhiteSpace uebergeben wuerde
				# das erst bei der Typkonvertierung auffallen.
				$certName = $TdeInfo.CertificateName
				if ($certName -is [System.DBNull]) { $certName = $null }
				$thumb = $TdeInfo.EncryptorThumbprint
				if ($thumb -is [System.DBNull]) { $thumb = $null }

				if ([string]::IsNullOrWhiteSpace($certName))
				{
					return [PSCustomObject]@{
						Proceed = $false
						Status  = 'TdeEncryptorNotCertificate'
						Message = "Datenbank '$DbName' ist TDE-verschluesselt, der Verschluesselungsschluessel haengt aber nicht an einem Serverzertifikat (Thumbprint $thumb), sondern an einem asymmetrischen Schluessel (EKM/Key Vault). Diesen Schluessel kann die Funktion nicht verteilen - der Provider muss auf allen Replicas eingerichtet sein."
					}
				}

				# Alle Replicas muessen SQL 2019 oder neuer sein, der Primary eingeschlossen
				$tooOld = @()
				foreach ($inst in @($SqlInstance) + @($secondaryInstances))
				{
					try
					{
						$vm = & $getVersionMajor $inst
					}
					catch
					{
						if ($EnableException) { throw }
						return [PSCustomObject]@{
							Proceed = $false
							Status  = 'TdeVersionCheckFailed'
							Message = "Datenbank '$DbName' ist TDE-verschluesselt, die SQL-Version von '$inst' liess sich aber nicht ermitteln: $($_.Exception.Message)"
						}
					}
					if ($vm -lt $tdeMinVersionMajor) { $tooOld += "$inst (SQL-Hauptversion $vm)" }
				}
				if ($tooOld.Count -gt 0)
				{
					return [PSCustomObject]@{
						Proceed = $false
						Status  = 'TdeUnsupportedVersion'
						Message = "Datenbank '$DbName' ist TDE-verschluesselt. Automatic Seeding verschluesselter Datenbanken gibt es erst ab SQL Server 2019 auf allen Replicas. Zu alt: $($tooOld -join ', '). Hier bleibt nur Backup/Restore mit vorher verteiltem Zertifikat."
					}
				}

				# Fehlt das Zertifikat irgendwo? Massstab ist der Thumbprint, nicht der Name -
				# SQL Server ordnet den Verschluesselungsschluessel ueber den Thumbprint zu.
				$missingOn = @()
				foreach ($secondary in $secondaryInstances)
				{
					try
					{
						$certQuery = "SELECT name FROM sys.certificates WHERE CONVERT(varchar(100), thumbprint, 1) = '$thumb'"
						$hit = Invoke-DbaQuery -SqlInstance $secondary -SqlCredential $SqlCredential -Database 'master' -Query $certQuery -EnableException
					}
					catch
					{
						if ($EnableException) { throw }
						return [PSCustomObject]@{
							Proceed = $false
							Status  = 'TdeCertificateCheckFailed'
							Message = "Zertifikatspruefung auf Secondary '$secondary' fehlgeschlagen: $($_.Exception.Message)"
						}
					}
					if (-not $hit) { $missingOn += $secondary }
				}

				if ($missingOn.Count -eq 0)
				{
					return [PSCustomObject]@{
						Proceed = $true
						Status  = 'TdeReady'
						Message = "TDE-Datenbank '$DbName': Zertifikat '$certName' ist auf allen Secondaries vorhanden."
					}
				}

				if (-not $SyncTdeCertificate)
				{
					return [PSCustomObject]@{
						Proceed = $false
						Status  = 'TdeCertificateMissing'
						Message = "Datenbank '$DbName' ist mit Zertifikat '$certName' verschluesselt, das auf folgenden Secondaries fehlt: $($missingOn -join ', '). Entweder mit -SyncTdeCertificate verteilen lassen oder vorher je Knoten mit Install-sqmCertificate -Purpose TDE einspielen."
					}
				}

				# --- Verteilung ---
				$certIdent = $certName -replace ']', ']]'

				# Export einmal je Zertifikat, auch wenn mehrere Datenbanken daran haengen
				if (-not $exportedCerts.ContainsKey($thumb))
				{
					$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
					$safeName = $certName -replace '[^\w\.\-]', '_'
					$cerFile = Join-Path -Path $TdeCertificateBackupPath -ChildPath "$($safeName)_$stamp.cer"
					$pvkFile = Join-Path -Path $TdeCertificateBackupPath -ChildPath "$($safeName)_$stamp.pvk"
					$exportAction = "Exportiere TDE-Zertifikat '$certName' nach '$TdeCertificateBackupPath'"
					if (-not $PSCmdlet.ShouldProcess($certName, $exportAction))
					{
						return [PSCustomObject]@{
							Proceed = $false
							Status  = 'TdeSyncSkipped'
							Message = "WhatIf: Zertifikat '$certName' waere nach $($missingOn -join ', ') verteilt worden."
						}
					}
					try
					{
						Invoke-sqmLogging -Message $exportAction -FunctionName $functionName -Level "INFO"
						$backupSql = @"
BACKUP CERTIFICATE [$certIdent] TO FILE = N'$($cerFile -replace "'", "''")'
WITH PRIVATE KEY (FILE = N'$($pvkFile -replace "'", "''")', ENCRYPTION BY PASSWORD = N'$($certPwPlain -replace "'", "''")');
"@
						Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database 'master' -Query $backupSql -EnableException
						$exportedCerts[$thumb] = [PSCustomObject]@{ CerFile = $cerFile; PvkFile = $pvkFile }
						# Zum Aufraeumen vormerken darf nur, was diese Sitzung auch sieht. Geschrieben
						# hat die Datei das Dienstkonto des Primary; zeigt der Pfad von dort woanders hin
						# als von hier (lokaler Pfad statt Freigabe), traefe ein Remove-Item eine
						# gleichnamige fremde Datei auf diesem Rechner.
						if ((Test-Path -Path $cerFile) -and (Test-Path -Path $pvkFile))
						{
							$exportedFiles.Add($cerFile)
							$exportedFiles.Add($pvkFile)
						}
						else
						{
							Invoke-sqmLogging -Message "Der Zertifikatsexport liegt unter '$TdeCertificateBackupPath', ist von dieser Sitzung aus aber nicht sichtbar - der Pfad ist offenbar nur auf '$SqlInstance' gueltig. Die Dateien werden deshalb nicht automatisch geloescht; '$([System.IO.Path]::GetFileName($pvkFile))' enthaelt den privaten Schluessel und muss dort von Hand entfernt werden." -FunctionName $functionName -Level "WARNING"
						}
					}
					catch
					{
						if ($EnableException) { throw }
						return [PSCustomObject]@{
							Proceed = $false
							Status  = 'TdeCertificateSyncFailed'
							Message = "Export des Zertifikats '$certName' fehlgeschlagen: $($_.Exception.Message). Schreibt das SQL-Dienstkonto von '$SqlInstance' in '$TdeCertificateBackupPath'?"
						}
					}
				}
				$files = $exportedCerts[$thumb]

				foreach ($secondary in $missingOn)
				{
					# Gleicher Name, anderer Thumbprint: CREATE CERTIFICATE wuerde mit
					# "already exists" scheitern. Das ist kein Uebertragungsfehler, sondern eine
					# Namenskollision und muss als solche gemeldet werden.
					try
					{
						$nameQuery = "SELECT CONVERT(varchar(100), thumbprint, 1) AS Thumb FROM sys.certificates WHERE name = N'$($certName -replace "'", "''")'"
						$nameHit = Invoke-DbaQuery -SqlInstance $secondary -SqlCredential $SqlCredential -Database 'master' -Query $nameQuery -EnableException
					}
					catch
					{
						if ($EnableException) { throw }
						return [PSCustomObject]@{
							Proceed = $false
							Status  = 'TdeCertificateCheckFailed'
							Message = "Namenspruefung auf Secondary '$secondary' fehlgeschlagen: $($_.Exception.Message)"
						}
					}
					if ($nameHit)
					{
						return [PSCustomObject]@{
							Proceed = $false
							Status  = 'TdeCertificateNameConflict'
							Message = "Auf Secondary '$secondary' existiert bereits ein Zertifikat namens '$certName', aber mit abweichendem Thumbprint ($($nameHit.Thumb) statt $thumb). Es gehoert zu einem anderen Schluessel und wird nicht ueberschrieben - Konflikt zuerst von Hand aufloesen."
						}
					}

					$createAction = "Erzeuge TDE-Zertifikat '$certName' auf Secondary '$secondary'"
					if (-not $PSCmdlet.ShouldProcess($secondary, $createAction))
					{
						return [PSCustomObject]@{
							Proceed = $false
							Status  = 'TdeSyncSkipped'
							Message = "WhatIf: Zertifikat '$certName' waere auf '$secondary' erzeugt worden."
						}
					}

					try
					{
						# CREATE CERTIFICATE ... WITH PRIVATE KEY verlangt einen
						# Datenbank-Hauptschluessel in master, der den Private Key schuetzt.
						$dmkQuery = "SELECT name FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##'"
						$dmk = Invoke-DbaQuery -SqlInstance $secondary -SqlCredential $SqlCredential -Database 'master' -Query $dmkQuery -EnableException
						if (-not $dmk)
						{
							Invoke-sqmLogging -Message "Lege Datenbank-Hauptschluessel in master auf '$secondary' an." -FunctionName $functionName -Level "INFO"
							$mkSql = "CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'$($mkPwPlain -replace "'", "''")';"
							Invoke-DbaQuery -SqlInstance $secondary -SqlCredential $SqlCredential -Database 'master' -Query $mkSql -EnableException
						}

						Invoke-sqmLogging -Message $createAction -FunctionName $functionName -Level "INFO"
						$createSql = @"
CREATE CERTIFICATE [$certIdent]
FROM FILE = N'$($files.CerFile -replace "'", "''")'
WITH PRIVATE KEY (FILE = N'$($files.PvkFile -replace "'", "''")', DECRYPTION BY PASSWORD = N'$($certPwPlain -replace "'", "''")');
"@
						Invoke-DbaQuery -SqlInstance $secondary -SqlCredential $SqlCredential -Database 'master' -Query $createSql -EnableException
					}
					catch
					{
						if ($EnableException) { throw }
						return [PSCustomObject]@{
							Proceed = $false
							Status  = 'TdeCertificateSyncFailed'
							Message = "Zertifikat '$certName' liess sich auf '$secondary' nicht erzeugen: $($_.Exception.Message). Liest das dortige SQL-Dienstkonto '$TdeCertificateBackupPath'?"
						}
					}
				}

				return [PSCustomObject]@{
					Proceed = $true
					Status  = 'TdeCertificateSynced'
					Message = "TDE-Datenbank '$DbName': Zertifikat '$certName' nach $($missingOn -join ', ') verteilt."
				}
			}

			# Datenbanken ermitteln
			$dbParams = @{ SqlInstance = $SqlInstance; SqlCredential = $SqlCredential; ExcludeSystem = $true; ErrorAction = 'Stop' }
			if ($EnableException) { $dbParams.EnableException = $true }
			
			if ($All)
			{
				$allDbs = Get-DbaDatabase @dbParams | Where-Object { $_.IsAccessible }
				$databases = @()
				foreach ($db in $allDbs)
				{
					$inAG = Get-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $db.Name -ErrorAction SilentlyContinue
					if (-not $inAG) { $databases += $db }
				}
				Invoke-sqmLogging -Message "$($databases.Count) Datenbanken wurden fuer Hinzufuegung ausgewaehlt." -FunctionName $functionName -Level "INFO"
			}
			elseif ($Database)
			{
				$dbParams.Database = $Database
				$databases = Get-DbaDatabase @dbParams | Where-Object { $_.IsAccessible }
				$missing = $Database | Where-Object { $_ -notin ($databases.Name) }
				if ($missing)
				{
					$msg = "Nicht gefunden: $($missing -join ', ')"
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $missing -join ','; Status = "NotFound"; Message = $msg }
				}
			}
			else { throw "Weder -All noch -Database angegeben." }
			
			if (-not $databases)
			{
				Invoke-sqmLogging -Message "Keine Datenbanken zum Hinzufuegen." -FunctionName $functionName -Level "WARNING"
				return
			}
			
			# Sequentiell verarbeiten (bei -All wichtig fuer Last)
			$counter = 0
			foreach ($db in $databases)
			{
				$counter++
				$dbName = $db.Name
				Invoke-sqmLogging -Message "Verarbeite Datenbank $counter von $($databases.Count): $dbName" -FunctionName $functionName -Level "INFO"
				
				# Pruefung ob bereits in AG (sicherheitshalber)
				$existingAg = Get-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $dbName -ErrorAction SilentlyContinue
				if ($existingAg)
				{
					$msg = "Datenbank '$dbName' ist bereits in AG '$($existingAg.AvailabilityGroupName)'. ueberspringe."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $dbName; Status = "AlreadyInAG"; Message = $msg }
					continue
				}

				# TDE-Voraussetzungen pruefen, solange noch nichts veraendert wurde
				$tdeInfo = $tdeMap[$dbName]
				if ($tdeInfo)
				{
					$tdeCheck = & $prepareTde $dbName $tdeInfo
					if (-not $tdeCheck.Proceed)
					{
						Invoke-sqmLogging -Message $tdeCheck.Message -FunctionName $functionName -Level "WARNING"
						$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $dbName; Status = $tdeCheck.Status; Message = $tdeCheck.Message }
						continue
					}
					Invoke-sqmLogging -Message $tdeCheck.Message -FunctionName $functionName -Level "INFO"
				}

				# Recovery-Modus auf Full setzen
				if ($db.RecoveryModel -ne 'Full')
				{
					$setRecoveryAction = "Setze Recovery-Modus fuer '$dbName' auf Full"
					if ($PSCmdlet.ShouldProcess($dbName, $setRecoveryAction))
					{
						try
						{
							Invoke-sqmLogging -Message $setRecoveryAction -FunctionName $functionName -Level "INFO"
							Set-DbaDbRecoveryModel -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $dbName -RecoveryModel Full -ErrorAction Stop
						}
						catch
						{
							$errMsg = "Fehler beim Setzen des Recovery-Modus: $($_.Exception.Message)"
							Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
							if ($EnableException) { throw }
							$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $dbName; Status = "SetRecoveryFailed"; Message = $errMsg }
							continue
						}
					}
					else
					{
						$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $dbName; Status = "RecoverySkipped"; Message = "WhatIf: Recovery-Modus nicht geaendert." }
						continue
					}
				}
				
				# Vorhandene Datenbank auf Secondaries loeschen
				foreach ($secondary in $secondaryInstances)
				{
					$secDb = Get-DbaDatabase -SqlInstance $secondary -SqlCredential $SqlCredential -Database $dbName -ErrorAction SilentlyContinue
					if ($secDb)
					{
						$dropAction = "Loesche vorhandene Datenbank '$dbName' auf Secondary '$secondary'"
						if ($PSCmdlet.ShouldProcess($dbName, $dropAction))
						{
							try
							{
								Invoke-sqmLogging -Message $dropAction -FunctionName $functionName -Level "INFO"
								Remove-DbaDatabase -SqlInstance $secondary -SqlCredential $SqlCredential -Database $dbName -Confirm:$false -ErrorAction Stop
							}
							catch
							{
								$errMsg = "Fehler beim Loeschen auf '$secondary': $($_.Exception.Message)"
								Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
								if ($EnableException) { throw }
								$results += [PSCustomObject]@{ SqlInstance = $secondary; DatabaseName = $dbName; Status = "DropOnSecondaryFailed"; Message = $errMsg }
								# Nicht abbrechen, versuchen trotzdem hinzuzufuegen?
							}
						}
						else
						{
							$results += [PSCustomObject]@{ SqlInstance = $secondary; DatabaseName = $dbName; Status = "DropSkipped"; Message = "WhatIf: Loeschen uebersprungen." }
						}
					}
				}
				
				# Zur AG hinzufuegen (mit Automatic Seeding)
				$addAction = "Fuege Datenbank '$dbName' zur AG '$AvailabilityGroup' hinzu (AutoSeed)"
				if ($PSCmdlet.ShouldProcess($dbName, $addAction))
				{
					try
					{
						Invoke-sqmLogging -Message $addAction -FunctionName $functionName -Level "INFO"
						Add-DbaAgDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -AvailabilityGroup $AvailabilityGroup -Database $dbName -SeedingMode Automatic -ErrorAction Stop
						$results += [PSCustomObject]@{
							SqlInstance  = $SqlInstance
							DatabaseName = $dbName
							Status	     = "Success"
							Message	     = "Erfolgreich zur AG hinzugefuegt."
						}
					}
					catch
					{
						$errMsg = "Fehler beim Hinzufuegen: $($_.Exception.Message)"
						Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
						if ($EnableException) { throw }
						$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $dbName; Status = "AddFailed"; Message = $errMsg }
					}
				}
				else
				{
					$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $dbName; Status = "AddSkipped"; Message = "WhatIf: Hinzufuegen uebersprungen." }
				}
			}
		}
		catch
		{
			$errMsg = "Allgemeiner Fehler: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			$results += [PSCustomObject]@{ SqlInstance = $SqlInstance; DatabaseName = $null; Status = "GlobalError"; Message = $errMsg }
		}
	}
	
	end
	{
		# Die .pvk traegt den privaten Schluessel des TDE-Zertifikats. Sie bleibt nur liegen,
		# wenn das ausdruecklich gewollt ist - und dann mit Hinweis.
		if ($exportedFiles.Count -gt 0)
		{
			if ($KeepTdeCertificateBackup)
			{
				Invoke-sqmLogging -Message "Zertifikatsexport bleibt liegen (-KeepTdeCertificateBackup): $($exportedFiles -join ', '). Die .pvk enthaelt den privaten Schluessel - sicher verwahren oder loeschen." -FunctionName $functionName -Level "WARNING"
			}
			else
			{
				foreach ($file in $exportedFiles)
				{
					try
					{
						if (Test-Path -Path $file) { Remove-Item -Path $file -Force -ErrorAction Stop }
					}
					catch
					{
						Invoke-sqmLogging -Message "Exportdatei '$file' konnte nicht geloescht werden: $($_.Exception.Message). Sie enthaelt Zertifikatsmaterial und muss von Hand entfernt werden." -FunctionName $functionName -Level "WARNING"
					}
				}
			}
		}

		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
		return $results
	}
}
