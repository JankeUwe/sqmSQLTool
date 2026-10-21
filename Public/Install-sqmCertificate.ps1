<#
.SYNOPSIS
    Installs a certificate (self-signed or CA-signed) in SQL Server and
    automatically binds it to the configured purpose.

.DESCRIPTION
    Supports three input formats:
      PFX   (.pfx)  - Certificate + private key in one file (CA-signed or exported).
                      Import into SQL Server requires SQL Server 2022 or later
                      (CREATE CERTIFICATE ... WITH FORMAT = 'PFX'). Older versions: use CER+PVK.
      CER+PVK       - Certificate (.cer) + encrypted private key (.pvk) separately
      CER only      - Certificate without private key (e.g. public key of an AlwaysOn partner)

    Process:
      1. Read certificate file and validate content (expiry date, subject, format)
      2. Check whether a certificate with the same name/thumbprint already exists in SQL Server
      3. Import certificate via CREATE CERTIFICATE in SQL Server (not for -Purpose SSL)
      4. Automatically bind based on -Purpose:
           AlwaysOn      -> with private key: ALTER ENDPOINT ... FOR DATABASE_MIRRORING
                            (AUTHENTICATION = CERTIFICATE <new>) on THIS instance.
                            Without private key (partner public key): NO endpoint change; the
                            certificate is owned by -AuthorizationUser (the database user of the
                            login that has CONNECT on the endpoint), which is what makes SQL Server
                            accept the partner replica.
           ServiceBroker -> same as AlwaysOn, with ALTER ENDPOINT ... FOR SERVICE_BROKER
           TDE           -> ALTER DATABASE ENCRYPTION KEY ENCRYPTION BY SERVER CERTIFICATE <new>
           SSL           -> Import into the Windows machine store (LocalMachine\My) only.
                            With -SetSqlServerSslCert the certificate is bound as TLS certificate
                            via Set-sqmSqlTlsCertificate (registry + private key permission for
                            the service account). Must run on the SQL Server host.
      5. Write installation log as TXT

    The certificate files are read twice: by PowerShell (validation) and by the SQL Server
    service account (CREATE CERTIFICATE ... FROM FILE). Use a path both can reach (e.g. UNC).
    Importing a private key requires a database master key in the target database.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the SQL Server connection.

.PARAMETER CertFile
    Path to the certificate file (.pfx, .cer, .crt, .p12).
    For PFX the private key is automatically imported.

.PARAMETER PrivateKeyFile
    Path to the separate private key file (.pvk). Only required for CER+PVK format.

.PARAMETER CertPassword
    Password for the PFX file or .pvk file (as SecureString).

.PARAMETER CertificateName
    Name under which the certificate is created in SQL Server.
    Default: file name without extension.

.PARAMETER Database
    Target database in SQL Server. Default: master.

.PARAMETER Purpose
    Purpose determines the automatic binding after import.
    Valid values: AlwaysOn, TDE, SSL, ServiceBroker, UserDefined.
    Default: UserDefined (no automatic binding).

.PARAMETER EndpointName
    Name of the endpoint for AlwaysOn/ServiceBroker binding (certificate with private key only).
    If not specified, the database mirroring endpoint (AlwaysOn) or the Service Broker
    endpoint (ServiceBroker) of the instance is used.

.PARAMETER AuthorizationUser
    Database user (in -Database, normally master) that becomes the owner of the certificate:
    CREATE CERTIFICATE ... AUTHORIZATION [user]. Needed for the public key of an AlwaysOn /
    Service Broker partner: the user belongs to the login that has CONNECT on the endpoint.
    The user must already exist.

.PARAMETER TdeDatabaseName
    Name of the database for TDE binding. If not specified, the current
    TDE-encrypted database on the instance is determined (only if unique).

.PARAMETER ReplaceCertificateName
    Name of an existing certificate that is replaced (endpoint/TDE switched)
    after successful installation. The old certificate is NOT deleted.

.PARAMETER ImportToWindowsStore
    Additionally import the certificate into the Windows machine certificate store
    (LocalMachine\My of the computer running the function).
    Required for SSL/TLS connections. Default: $false; automatically $true when Purpose=SSL.

.PARAMETER SetSqlServerSslCert
    Bind this certificate as TLS certificate of the instance via Set-sqmSqlTlsCertificate:
    thumbprint in SuperSocketNetLib, Read permission on the private key for the service account.
    Run on the SQL Server host. Requires a restart of the SQL Server service. Default: $false.

.PARAMETER OutputPath
    Output directory for the installation log. Default: from module configuration.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    # Import PFX (SQL Server 2022+) and switch the local AlwaysOn endpoint to it
    Install-sqmCertificate -SqlInstance "SQL01" -CertFile "\\fs01\certs\sql01_ag.pfx" `
        -CertPassword (Read-Host -AsSecureString) -Purpose AlwaysOn

.EXAMPLE
    # Public key of the partner SQL01 on replica SQL02 (no private key, no endpoint change).
    # ag_user_sql01 = database user in master of the login with CONNECT on the endpoint.
    Install-sqmCertificate -SqlInstance "SQL02" -CertFile "\\fs01\certs\SQL01_AG_CERT.cer" `
        -CertificateName "SQL01_AG_CERT" -Purpose AlwaysOn -AuthorizationUser "ag_user_sql01"

.EXAMPLE
    # Install CER + PVK and bind TDE
    Install-sqmCertificate -SqlInstance "SQL01" `
        -CertFile "C:\Certs\tde_new.cer" `
        -PrivateKeyFile "C:\Certs\tde_new.pvk" `
        -CertPassword (Read-Host -AsSecureString "PVK password") `
        -Purpose TDE -TdeDatabaseName "ProdDB"

.EXAMPLE
    # TLS certificate: Windows store + binding (on the SQL Server host, restart afterwards)
    Install-sqmCertificate -SqlInstance "SQL01" -CertFile "C:\Certs\ssl.pfx" `
        -CertPassword (Read-Host -AsSecureString) -Purpose SSL -SetSqlServerSslCert

.NOTES
    Requires: dbatools, Invoke-sqmLogging, Get-sqmDefaultOutputPath, Copy-sqmToCentralPath
    Needs: sysadmin on the SQL Server instance; local administrator for -Purpose SSL.
    SSL binding (-SetSqlServerSslCert): Requires a restart of the SQL Server service.
    AlwaysOn renewal: import the new public key on ALL partners (-AuthorizationUser) BEFORE
    switching the endpoint on the owning replica, otherwise the replicas disconnect.
    PFX import into SQL Server: SQL Server 2022+ only.
    Certificate files are NOT deleted after the import.
#>
function Install-sqmCertificate
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $true)]
		[ValidateScript({ Test-Path $_ -PathType Leaf })]
		[string]$CertFile,
		[Parameter(Mandatory = $false)]
		[ValidateScript({ -not $_ -or (Test-Path $_ -PathType Leaf) })]
		[string]$PrivateKeyFile,
		[Parameter(Mandatory = $false)]
		[System.Security.SecureString]$CertPassword,
		[Parameter(Mandatory = $false)]
		[string]$CertificateName,
		[Parameter(Mandatory = $false)]
		[string]$Database = 'master',
		[Parameter(Mandatory = $false)]
		[ValidateSet('AlwaysOn', 'TDE', 'SSL', 'ServiceBroker', 'UserDefined')]
		[string]$Purpose = 'UserDefined',
		[Parameter(Mandatory = $false)]
		[string]$EndpointName,
		[Parameter(Mandatory = $false)]
		[string]$AuthorizationUser,
		[Parameter(Mandatory = $false)]
		[string]$TdeDatabaseName,
		[Parameter(Mandatory = $false)]
		[string]$ReplaceCertificateName,
		[Parameter(Mandatory = $false)]
		[switch]$ImportToWindowsStore,
		[Parameter(Mandatory = $false)]
		[switch]$SetSqlServerSslCert,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
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
		
		if (-not $OutputPath) { $OutputPath = Join-Path (Get-sqmDefaultOutputPath) 'CertInstall' }
		
		# SSL setzt Windows-Store-Import voraus
		if ($Purpose -eq 'SSL') { $ImportToWindowsStore = $true }
		
		Invoke-sqmLogging -Message ("Starte " + $functionName + ": '$CertFile' auf $SqlInstance (Purpose=$Purpose)") -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		try
		{
			$datestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
			$certExt = [System.IO.Path]::GetExtension($CertFile).ToLower()
			$isPfx = $certExt -in @('.pfx', '.p12')
			$hasPvk = [bool]$PrivateKeyFile
			$hasPrivKey = $isPfx -or $hasPvk
			
			# Zertifikatsnamen aus Dateinamen ableiten wenn nicht angegeben
			if (-not $CertificateName)
			{
				$CertificateName = [System.IO.Path]::GetFileNameWithoutExtension($CertFile) -replace '[^a-zA-Z0-9_]', '_'
			}
			
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
			# 1. Zertifikatsdatei lesen und vorab validieren
			# -------------------------------------------------------------------
			$certInfo = Get-sqmCertFileInfo -CertFile $CertFile -CertPassword $CertPassword -IsPfx $isPfx
			
			Invoke-sqmLogging -Message "Zertifikat gelesen: Subject='$($certInfo.Subject)', Ablauf=$($certInfo.NotAfter.ToString('yyyy-MM-dd'))" -FunctionName $functionName -Level "INFO"
			
			# Ablaufdatum warnen (nicht blockieren - Installation eines abgelaufenen Zerts kann gewollt sein)
			if ($certInfo.NotAfter -lt (Get-Date))
			{
				Write-Warning "ACHTUNG: Das Zertifikat '$CertificateName' ist bereits abgelaufen ($($certInfo.NotAfter.ToString('yyyy-MM-dd')))!"
				Invoke-sqmLogging -Message "Zertifikat ist abgelaufen: $($certInfo.NotAfter)" -FunctionName $functionName -Level "WARNING"
			}
			elseif ($certInfo.NotAfter -lt (Get-Date).AddDays(30))
			{
				Write-Warning "HINWEIS: Zertifikat laeuft in weniger als 30 Tagen ab ($($certInfo.NotAfter.ToString('yyyy-MM-dd')))."
			}
			
			# -------------------------------------------------------------------
			# 2. Pruefen ob Zertifikat bereits in SQL Server existiert
			# -------------------------------------------------------------------
			# Purpose SSL: TLS-Zertifikate gehoeren in den Windows-Store, nicht nach sys.certificates
			$importToSql = ($Purpose -ne 'SSL')
			$existingInSql = $null
			$sqlMajorVersion = 0

			if ($importToSql)
			{
				$preQuery = @"
SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS MajorVersion,
       (SELECT COUNT(*) FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##') AS HasDmk
"@
				$pre = Invoke-DbaQuery @connParams -Query $preQuery -ErrorAction Stop
				$sqlMajorVersion = [int]$pre.MajorVersion

				if ($isPfx -and $sqlMajorVersion -lt 16)
				{
					throw "PFX-Import in SQL Server erst ab SQL Server 2022 (CREATE CERTIFICATE ... WITH FORMAT = 'PFX'). Instanz '$SqlInstance' ist Version $sqlMajorVersion. Zertifikat als CER + PVK bereitstellen (-CertFile .cer -PrivateKeyFile .pvk)."
				}
				if ($hasPrivKey -and [int]$pre.HasDmk -eq 0)
				{
					throw "In Datenbank '$Database' existiert kein Database Master Key. Ein Private Key kann nur importiert werden, wenn er per DMK geschuetzt werden kann. Zuerst: USE [$Database]; CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<sicheres Passwort>';"
				}
				if ($AuthorizationUser)
				{
					$userQuery = "SELECT name FROM sys.database_principals WHERE name = '$($AuthorizationUser -replace "'", "''")' AND type IN ('S','U','G','C','E','X')"
					if (-not (Invoke-DbaQuery @connParams -Query $userQuery -ErrorAction Stop))
					{
						throw "Datenbankbenutzer '$AuthorizationUser' existiert nicht in '$Database'. Zuerst anlegen (CREATE USER [$AuthorizationUser] FOR LOGIN [...])."
					}
				}

				$existsQuery = "SELECT name, thumbprint FROM sys.certificates WHERE name = '$($CertificateName -replace "'", "''")'"
				$existingInSql = Invoke-DbaQuery @connParams -Query $existsQuery -ErrorAction SilentlyContinue
			}

			if ($existingInSql)
			{
				$existingThumb = [System.BitConverter]::ToString($existingInSql.thumbprint).Replace('-', '')
				if ($existingThumb -eq $certInfo.Thumbprint)
				{
					Write-Warning "Zertifikat '$CertificateName' mit identischem Thumbprint ist bereits in SQL Server vorhanden. ueberspringe Import."
					Invoke-sqmLogging -Message "Zertifikat bereits vorhanden (gleicher Thumbprint). Fahre mit Bindung fort." -FunctionName $functionName -Level "WARNING"
				}
				else
				{
					throw "Ein Zertifikat mit dem Namen '$CertificateName' existiert bereits in SQL Server mit anderem Thumbprint. Bitte anderen -CertificateName angeben oder bestehendes Zertifikat entfernen."
				}
			}
			
			# -------------------------------------------------------------------
			# 3. ShouldProcess
			# -------------------------------------------------------------------
			$action = "Zertifikat '$CertificateName' in SQL Server '$SqlInstance' installieren (Purpose: $Purpose)"
			if (-not $PSCmdlet.ShouldProcess($SqlInstance, $action))
			{
				Invoke-sqmLogging -Message "Abgebrochen durch ShouldProcess." -FunctionName $functionName -Level "INFO"
				return $null
			}
			
			# -------------------------------------------------------------------
			# 4. Zertifikat in SQL Server importieren
			# -------------------------------------------------------------------
			$installResult = [PSCustomObject]@{
				SqlInstance	    = $SqlInstance
				CertificateName = $CertificateName
				Subject		    = $certInfo.Subject
				Thumbprint	    = $certInfo.Thumbprint
				NotAfter	    = $certInfo.NotAfter
				Purpose		    = $Purpose
				SqlImported	    = $false
				WindowsStoreImport = $false
				SslCertSet	    = $false
				EndpointBound   = $false
				PartnerKeyOwner = $null
				TdeBound	    = $false
				ProtocolFile    = $null
				Success		    = $false
				ErrorMessage    = $null
				Warnings	    = [System.Collections.Generic.List[string]]::new()
			}
			
			if ($importToSql -and -not $existingInSql)
			{
				$importSql = New-sqmCertImportSql `
													-CertificateName $CertificateName `
													-CertFile $CertFile `
													-PrivateKeyFile $PrivateKeyFile `
													-CertPassword $CertPassword `
													-IsPfx $isPfx `
													-HasPrivKey $hasPrivKey `
													-AuthorizationUser $AuthorizationUser

				Invoke-DbaQuery @connParams -Query $importSql -ErrorAction Stop
				$installResult.SqlImported = $true
				if ($AuthorizationUser) { $installResult.PartnerKeyOwner = $AuthorizationUser }
				Invoke-sqmLogging -Message "Zertifikat '$CertificateName' erfolgreich in SQL Server importiert." -FunctionName $functionName -Level "INFO"
			}
			elseif ($importToSql)
			{
				$installResult.SqlImported = $true # war bereits vorhanden
				if ($AuthorizationUser)
				{
					$alterAuthSql = "ALTER AUTHORIZATION ON CERTIFICATE::[$CertificateName] TO [$AuthorizationUser];"
					Invoke-DbaQuery @connParams -Query $alterAuthSql -ErrorAction Stop
					$installResult.PartnerKeyOwner = $AuthorizationUser
					Invoke-sqmLogging -Message "Besitzer von '$CertificateName' auf '$AuthorizationUser' gesetzt." -FunctionName $functionName -Level "INFO"
				}
			}
			
			# -------------------------------------------------------------------
			# 5. Windows-Maschinen-Store importieren (fuer SSL)
			# -------------------------------------------------------------------
			if ($ImportToWindowsStore)
			{
				try
				{
					Add-sqmCertToMachineStore -CertFile $CertFile -CertPassword $CertPassword -IsPfx $isPfx
					$installResult.WindowsStoreImport = $true
					Invoke-sqmLogging -Message "Zertifikat in Windows Maschinen-Store (LocalMachine\My) importiert." -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					$warnMsg = "Windows-Store-Import fehlgeschlagen: $($_.Exception.Message)"
					Write-Warning $warnMsg
					$installResult.Warnings.Add($warnMsg)
					Invoke-sqmLogging -Message $warnMsg -FunctionName $functionName -Level "WARNING"
				}
			}
			
			# -------------------------------------------------------------------
			# 6. SQL Server Netzwerkkonfiguration (SSL-Zertifikat setzen)
			# -------------------------------------------------------------------
			if ($SetSqlServerSslCert -and $installResult.WindowsStoreImport)
			{
				try
				{
					# Bindung inkl. Registry-Schluessel aus 'Instance Names\SQL' und Private-Key-Recht
					# fuer das Dienstkonto: dieselbe Logik wie Set-sqmSqlTlsCertificate (frueher wurde
					# hier ein Registry-Pfad aus einer nie gesetzten Variable gebaut).
					$tlsResult = Set-sqmSqlTlsCertificate -SqlInstance $SqlInstance -Thumbprint $certInfo.Thumbprint -Confirm:$false -ErrorAction Stop
					$installResult.SslCertSet = $true
					Invoke-sqmLogging -Message "TLS-Zertifikat gebunden (Thumbprint: $($certInfo.Thumbprint))." -FunctionName $functionName -Level "INFO"
					if ($tlsResult -and -not $tlsResult.PrivateKeyGranted)
					{
						$installResult.Warnings.Add("Leserecht auf den Private Key fuer '$($tlsResult.ServiceAccount)' konnte nicht gesetzt werden - manuell vergeben, sonst startet der Dienst nicht.")
					}
					$installResult.Warnings.Add("SQL Server-Dienst muss neu gestartet werden, damit das TLS-Zertifikat aktiv wird.")
				}
				catch
				{
					$warnMsg = "SSL-Zertifikat in Registry konnte nicht gesetzt werden: $($_.Exception.Message)"
					Write-Warning $warnMsg
					$installResult.Warnings.Add($warnMsg)
					Invoke-sqmLogging -Message $warnMsg -FunctionName $functionName -Level "WARNING"
				}
			}
			
			# -------------------------------------------------------------------
			# 7. Endpoint-Bindung (AlwaysOn / ServiceBroker)
			# -------------------------------------------------------------------
			if ($Purpose -in @('AlwaysOn', 'ServiceBroker') -and -not $hasPrivKey)
			{
				# Public Key eines Partners: Endpoint NICHT umstellen (ein Endpoint braucht ein
				# Zertifikat mit Private Key). Massgeblich ist der Besitzer des Zertifikats.
				if (-not $installResult.PartnerKeyOwner)
				{
					$warnMsg = "Public Key ohne -AuthorizationUser importiert (Besitzer: dbo). Damit der Partner akzeptiert wird: ALTER AUTHORIZATION ON CERTIFICATE::[$CertificateName] TO [<Benutzer des Endpoint-Logins>]; und GRANT CONNECT ON ENDPOINT::[<Endpoint>] TO [<Login>];"
					Write-Warning $warnMsg
					$installResult.Warnings.Add($warnMsg)
				}
				Invoke-sqmLogging -Message "Partner-Public-Key '$CertificateName' importiert, Endpoint unveraendert." -FunctionName $functionName -Level "INFO"
			}
			elseif ($Purpose -in @('AlwaysOn', 'ServiceBroker'))
			{
				$epToUse = $EndpointName
				$epClause = if ($Purpose -eq 'ServiceBroker') { 'SERVICE_BROKER' }
				else { 'DATABASE_MIRRORING' }

				# Automatisch ermitteln wenn nicht angegeben
				if (-not $epToUse)
				{
					$epView = if ($Purpose -eq 'ServiceBroker') { 'sys.service_broker_endpoints' }
					else { 'sys.database_mirroring_endpoints' }
					$epQuery = "SELECT TOP 1 name FROM $epView ORDER BY endpoint_id"
					$autoEp = Invoke-DbaQuery @masterParams -Query $epQuery -ErrorAction SilentlyContinue
					$epToUse = $autoEp.name
				}

				if ($epToUse)
				{
					try
					{
						$alterEpSql = "ALTER ENDPOINT [$epToUse] FOR $epClause (AUTHENTICATION = CERTIFICATE [$CertificateName]);"
						Invoke-DbaQuery @masterParams -Query $alterEpSql -ErrorAction Stop -EnableException
						$installResult.EndpointBound = $true
						Invoke-sqmLogging -Message "Endpoint '$epToUse' auf '$CertificateName' umgestellt." -FunctionName $functionName -Level "INFO"
					}
					catch
					{
						$warnMsg = "Endpoint-Bindung fehlgeschlagen: $($_.Exception.Message)"
						Write-Warning $warnMsg
						$installResult.Warnings.Add($warnMsg)
					}
				}
				else
				{
					$warnMsg = "Kein passender Endpoint gefunden. Bitte -EndpointName angeben."
					Write-Warning $warnMsg
					$installResult.Warnings.Add($warnMsg)
				}
			}
			
			# -------------------------------------------------------------------
			# 8. TDE-Bindung
			# -------------------------------------------------------------------
			if ($Purpose -eq 'TDE')
			{
				$tdeDbName = $TdeDatabaseName
				
				# Automatisch ermitteln wenn nicht angegeben und eindeutig
				if (-not $tdeDbName)
				{
					$tdeAutoQuery = @"
SELECT d.name
FROM sys.dm_database_encryption_keys dek
INNER JOIN sys.databases d ON dek.database_id = d.database_id
WHERE dek.encryption_state = 3
"@
					$tdeDbs = Invoke-DbaQuery @masterParams -Query $tdeAutoQuery -ErrorAction SilentlyContinue
					if (@($tdeDbs).Count -eq 1) { $tdeDbName = $tdeDbs.name }
					elseif (@($tdeDbs).Count -gt 1)
					{
						$warnMsg = "Mehrere TDE-verschluesselte Datenbanken gefunden. Bitte -TdeDatabaseName angeben: $($tdeDbs.name -join ', ')"
						Write-Warning $warnMsg
						$installResult.Warnings.Add($warnMsg)
					}
				}
				
				if ($tdeDbName)
				{
					if (-not $hasPrivKey)
					{
						$warnMsg = "TDE-Zertifikat ohne Private Key kann nicht fuer TDE-Verschluesselung verwendet werden."
						Write-Warning $warnMsg
						$installResult.Warnings.Add($warnMsg)
					}
					else
					{
						try
						{
							$alterTdeSql = @"
USE [$tdeDbName];
ALTER DATABASE ENCRYPTION KEY ENCRYPTION BY SERVER CERTIFICATE [$CertificateName];
"@
							Invoke-DbaQuery @masterParams -Query $alterTdeSql -ErrorAction Stop -EnableException
							$installResult.TdeBound = $true
							Invoke-sqmLogging -Message "TDE fuer '$tdeDbName' auf '$CertificateName' umgestellt." -FunctionName $functionName -Level "INFO"
						}
						catch
						{
							$warnMsg = "TDE-Bindung fehlgeschlagen: $($_.Exception.Message)"
							Write-Warning $warnMsg
							$installResult.Warnings.Add($warnMsg)
						}
					}
				}
			}
			
			# -------------------------------------------------------------------
			# 9. Altes Zertifikat abloesen (Endpoint/TDE umstellen)
			# -------------------------------------------------------------------
			if ($ReplaceCertificateName)
			{
				Invoke-sqmLogging -Message "Altes Zertifikat '$ReplaceCertificateName' abgeloest. Loeschen nach Verifikation: DROP CERTIFICATE [$ReplaceCertificateName];" -FunctionName $functionName -Level "INFO"
				$installResult.Warnings.Add("Altes Zertifikat '$ReplaceCertificateName' ist noch vorhanden. Nach Verifikation loeschen: DROP CERTIFICATE [$ReplaceCertificateName];")
			}
			
			# -------------------------------------------------------------------
			# 10. Installationsprotokoll schreiben
			# -------------------------------------------------------------------
			if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
			
			$safeInstance = $SqlInstance -replace '\\', '_'
			$protFile = Join-Path $OutputPath "CertInstall_${safeInstance}_${CertificateName}_${datestamp}.txt"
			$lines = [System.Collections.Generic.List[string]]::new()
			
			$lines.Add("=" * 70)
			$lines.Add("  ZERTIFIKAT-INSTALLATIONSPROTOKOLL")
			$lines.Add("  Datum     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
			$lines.Add("  Instanz   : $SqlInstance")
			$lines.Add("  Datenbank : $Database")
			$lines.Add("=" * 70)
			$lines.Add("")
			$lines.Add("ZERTIFIKAT")
			$lines.Add("-" * 40)
			$lines.Add("  Name         : $CertificateName")
			$lines.Add("  Subject      : $($certInfo.Subject)")
			$lines.Add("  Aussteller   : $($certInfo.Issuer)")
			$lines.Add("  Gueltig von   : $($certInfo.NotBefore.ToString('yyyy-MM-dd'))")
			$lines.Add("  Gueltig bis   : $($certInfo.NotAfter.ToString('yyyy-MM-dd'))")
			$lines.Add("  Thumbprint   : $($certInfo.Thumbprint)")
			$lines.Add("  Private Key  : $(if ($hasPrivKey) { 'Ja' }
					else { 'Nein (nur Public Key)' })")
			$lines.Add("  Quelldatei   : $CertFile")
			if ($PrivateKeyFile) { $lines.Add("  PVK-Datei    : $PrivateKeyFile") }
			$lines.Add("  Verwendung   : $Purpose")
			$lines.Add("")
			$lines.Add("INSTALLATIONSERGEBNIS")
			$lines.Add("-" * 40)
			$lines.Add("  SQL Import         : $(if ($installResult.SqlImported) { 'OK' }
					elseif (-not $importToSql) { 'Nicht zutreffend (TLS)' }
					else { 'FEHLER' })")
			$lines.Add("  Windows Store      : $(if ($installResult.WindowsStoreImport) { 'OK' }
					elseif ($ImportToWindowsStore) { 'FEHLER' }
					else { 'Nicht durchgefuehrt' })")
			$lines.Add("  SSL-Zertifikat     : $(if ($installResult.SslCertSet) { 'OK - Neustart erforderlich!' }
					elseif ($SetSqlServerSslCert) { 'FEHLER' }
					else { 'Nicht gesetzt' })")
			$lines.Add("  Endpoint-Bindung   : $(if ($installResult.EndpointBound) { 'OK' }
					elseif ($Purpose -in 'AlwaysOn', 'ServiceBroker' -and -not $hasPrivKey) { 'Nicht zutreffend (Partner-Public-Key)' }
					elseif ($Purpose -in 'AlwaysOn', 'ServiceBroker') { 'FEHLGESCHLAGEN - manuell binden' }
					else { 'Nicht zutreffend' })")
			if ($Purpose -in 'AlwaysOn', 'ServiceBroker' -and -not $hasPrivKey)
			{
				$lines.Add("  Besitzer (Partner) : $(if ($installResult.PartnerKeyOwner) { $installResult.PartnerKeyOwner }
						else { 'dbo - Besitzer setzen, siehe Warnungen' })")
			}
			$lines.Add("  TDE-Bindung        : $(if ($installResult.TdeBound) { 'OK' }
					elseif ($Purpose -eq 'TDE') { 'FEHLGESCHLAGEN - manuell binden' }
					else { 'Nicht zutreffend' })")
			$lines.Add("")
			
			if ($installResult.Warnings.Count -gt 0)
			{
				$lines.Add("WARNUNGEN")
				$lines.Add("-" * 40)
				foreach ($w in $installResult.Warnings) { $lines.Add("  ! $w") }
				$lines.Add("")
			}
			
			# Purpose-spezifische Nacharbeiten
			if ($Purpose -eq 'AlwaysOn' -and $hasPrivKey)
			{
				$lines.Add("WEITERE SCHRITTE - ALWAYSON")
				$lines.Add("-" * 40)
				$lines.Add("  Die Partner-Replikate muessen den Public Key dieses Zertifikats kennen,")
				$lines.Add("  sonst lehnen sie diesen Endpoint ab. Vorgehen fuer jedes Partner-Replikat:")
				$lines.Add("")
				$lines.Add("  1. Public Key exportieren (auf DIESER Instanz):")
				$lines.Add("     BACKUP CERTIFICATE [$CertificateName] TO FILE = N'\\<Share>\$CertificateName.cer';")
				$lines.Add("")
				$lines.Add("  2. Auf jedem Partner importieren, Besitzer = Benutzer des Endpoint-Logins:")
				$lines.Add("     Install-sqmCertificate -SqlInstance '<Partner>' \")
				$lines.Add("         -CertFile '\\<Share>\$CertificateName.cer' \")
				$lines.Add("         -CertificateName '$CertificateName' \")
				$lines.Add("         -Purpose AlwaysOn -AuthorizationUser '<Benutzer>'")
				$lines.Add("")
				$lines.Add("  Bei einer Erneuerung: Schritt 1 und 2 VOR dem Umstellen des Endpoints.")
				$lines.Add("")
				$lines.Add("  3. AG-Replikation und Sync-Status pruefen:")
				$lines.Add("     Get-sqmAlwaysOnHealthReport -SqlInstance '<Primary>'")
			}
			
			if ($Purpose -eq 'TDE')
			{
				$lines.Add("WEITERE SCHRITTE - TDE")
				$lines.Add("-" * 40)
				$lines.Add("  PFLICHT: Neues TDE-Zertifikat sofort sichern (inkl. Private Key)!")
				$lines.Add("  BACKUP CERTIFICATE [$CertificateName] TO FILE = N'<Pfad>\$CertificateName.cer'")
				$lines.Add("  WITH PRIVATE KEY (")
				$lines.Add("      FILE               = N'<Pfad>\$CertificateName.pvk',")
				$lines.Add("      ENCRYPTION BY PASSWORD = N'<sicheres Passwort>'")
				$lines.Add("  );")
				$lines.Add("  Backup sicher und getrennt vom Server aufbewahren!")
			}
			
			if ($Purpose -eq 'SSL' -and $installResult.SslCertSet)
			{
				$lines.Add("WEITERE SCHRITTE - SSL")
				$lines.Add("-" * 40)
				$lines.Add("  SQL Server-Dienst neu starten:")
				$lines.Add("  Restart-Service MSSQLSERVER   (oder benannte Instanz)")
				$lines.Add("  Nach Neustart: Verschluesselte Verbindungen testen.")
			}
			
			$lines | Out-File -FilePath $protFile -Encoding UTF8 -Force
			$installResult.ProtocolFile = $protFile
			$installResult.Success = if ($importToSql) { $installResult.SqlImported }
			else { $installResult.WindowsStoreImport -and (-not $SetSqlServerSslCert -or $installResult.SslCertSet) }
			
			Invoke-sqmLogging -Message "Installationsprotokoll: $protFile" -FunctionName $functionName -Level "INFO"
			Copy-sqmToCentralPath -Path @($protFile)
			
			Write-Host "Zertifikat '$CertificateName' installiert auf $SqlInstance." -ForegroundColor Green
			Write-Host "Protokoll: $protFile" -ForegroundColor Cyan
			if ($installResult.Warnings.Count -gt 0)
			{
				Write-Host "$($installResult.Warnings.Count) Warnung(en) - siehe Protokoll." -ForegroundColor Yellow
			}
			
			return $installResult
		}
		catch
		{
			$errMsg = "Fehler bei Zertifikats-Installation: $($_.Exception.Message)"
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

# ---------------------------------------------------------------------------
# Private Hilfsfunktionen
# ---------------------------------------------------------------------------

function Get-sqmCertFileInfo
{
	param (
		[string]$CertFile,
		[System.Security.SecureString]$CertPassword,
		[bool]$IsPfx
	)
	try
	{
		if ($IsPfx)
		{
			$pfxBytes = [System.IO.File]::ReadAllBytes($CertFile)
			$x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
				$pfxBytes,
				$CertPassword,
				[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
			)
		}
		else
		{
			$x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CertFile)
		}
		
		return [PSCustomObject]@{
			Subject = $x509.Subject
			Issuer  = $x509.Issuer
			NotBefore = $x509.NotBefore
			NotAfter = $x509.NotAfter
			Thumbprint = $x509.Thumbprint
		}
	}
	catch
	{
		throw "Zertifikatsdatei kann nicht gelesen werden: $($_.Exception.Message). Passwort korrekt?"
	}
}

function Add-sqmCertToMachineStore
{
	param (
		[string]$CertFile,
		[System.Security.SecureString]$CertPassword,
		[bool]$IsPfx
	)
	if ($IsPfx)
	{
		$pfxBytes = [System.IO.File]::ReadAllBytes($CertFile)
		$x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
			$pfxBytes,
			$CertPassword,
			[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor
			[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
		)
	}
	else
	{
		$x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CertFile)
	}

	$store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
		[System.Security.Cryptography.X509Certificates.StoreName]::My,
		[System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
	)
	$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
	try { $store.Add($x509) }
	finally { $store.Close() }
}

function New-sqmCertImportSql
{
	param (
		[string]$CertificateName,
		[string]$CertFile,
		[string]$PrivateKeyFile,
		[System.Security.SecureString]$CertPassword,
		[bool]$IsPfx,
		[bool]$HasPrivKey,
		[string]$AuthorizationUser
	)

	# Passwort entschluesseln (nur temporaer im Speicher)
	$plainPwd = $null
	if ($CertPassword)
	{
		$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($CertPassword)
		$plainPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
		[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
	}

	try
	{
		$q = { param ($s) $s -replace "'", "''" }
		$authClause = if ($AuthorizationUser) { " AUTHORIZATION [$($AuthorizationUser -replace '\]', ']]')]" }
		else { '' }
		$head = "CREATE CERTIFICATE [$($CertificateName -replace '\]', ']]')]$authClause`r`nFROM FILE = N'$(& $q $CertFile)'"
		$pwdClause = if ($plainPwd) { "DECRYPTION BY PASSWORD = N'$(& $q $plainPwd)'" }
		else { '' }

		if ($IsPfx)
		{
			# PFX: erst ab SQL Server 2022, Format muss explizit angegeben werden - ohne
			# FORMAT = 'PFX' erwartet FROM FILE ein DER-Zertifikat und PRIVATE KEY FILE eine PVK-Datei.
			$keyClause = if ($pwdClause) { ",`r`n     PRIVATE KEY ($pwdClause)" }
			else { '' }
			return "$head`r`nWITH FORMAT = 'PFX'$keyClause;"
		}
		elseif ($PrivateKeyFile)
		{
			$pvk = "FILE = N'$(& $q $PrivateKeyFile)'"
			if ($pwdClause) { $pvk += ", $pwdClause" }
			return "$head`r`nWITH PRIVATE KEY ($pvk);"
		}
		else
		{
			# Nur Public Key (CER ohne Private Key)
			return "$head;"
		}
	}
	finally
	{
		$plainPwd = $null # Passwort aus Speicher entfernen
	}
}

# Backward compatibility: old name "Build-sqmCertImportSql" -> new name "New-sqmCertImportSql"
Set-Alias -Name 'Build-sqmCertImportSql' -Value 'New-sqmCertImportSql' -Force