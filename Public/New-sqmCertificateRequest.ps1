<#
.SYNOPSIS
    Creates a CSR (Certificate Signing Request) and an order data sheet for a
    CA-signed certificate based on an existing SQL Server certificate.

.DESCRIPTION
    Reads all relevant properties of the existing certificate from SQL Server
    (Subject, SANs, purpose, endpoint binding) and creates:

    1. INF file (certreq configuration) with all fields from the existing certificate
    2. CSR file (.csr / PKCS#10) via Windows certreq.exe or New-SelfSignedCertificate
    3. Order data sheet (.txt) with:
         - All information for the CA order (Subject, SANs, Key Usage, EKU)
         - Suggested certificate type based on purpose
         - Checklist for the ordering process
         - T-SQL commands for later installation
    4. Optional: Generate private key locally and store securely

    PURPOSE-SPECIFIC HANDLING:
      AlwaysOn / Mirroring  -> Key Usage: Digital Signature, Key Encipherment
                               EKU: Server Authentication (1.3.6.1.5.5.7.3.1)
      TDE                   -> Note: TDE typically uses self-signed certificates;
                               CA-signed certificates are possible but uncommon
      SSL/TLS connections   -> Key Usage: Digital Signature, Key Encipherment
                               EKU: Server Authentication + Client Authentication
      Service Broker        -> Key Usage: Digital Signature, Key Encipherment

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name). Used for SAN and order sheet.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER CertificateName
    Name of the existing certificate to use as a template. If not specified, a new
    certificate is created without a template (-Subject then becomes required).

.PARAMETER Database
    Database where the certificate resides. Default: master.

.PARAMETER Subject
    Subject (CN) of the new certificate. Overrides the value from the existing certificate.
    Format: CN=SQL01.domain.com,O=Company,L=City,S=State,C=DE

.PARAMETER SubjectAlternativeNames
    Additional SANs (DNS names or IP addresses).
    Automatically extended with: FQDN, NetBIOS name, AG listener (if detected).

.PARAMETER KeyLength
    Key length in bits. Default: 2048. Recommended for new installations: 4096.

.PARAMETER ValidityYears
    Desired validity period in years (information for the CA, not guaranteed). Default: 3.

.PARAMETER Purpose
    Purpose when no existing certificate is used as a template.
    Valid values: AlwaysOn, TDE, SSL, ServiceBroker, UserDefined.

.PARAMETER OutputPath
    Output directory for CSR, INF, and order data sheet. Default: $env:ProgramData\sqmSQLTool\Logs\Cert

.PARAMETER Organization
    Organization name for the certificate (O=). Default: from existing certificate or computer name.

.PARAMETER OrganizationalUnit
    Organizational unit (OU=). Optional.

.PARAMETER Locality
    City/locality (L=). Optional.

.PARAMETER State
    State/province (S=). Optional.

.PARAMETER Country
    Two-letter country code (C=). Default: DE.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    # CSR based on an existing certificate
    New-sqmCertificateRequest -SqlInstance "SQL01" -CertificateName "AG_CERT"

.EXAMPLE
    # New CSR without template, all fields specified manually
    New-sqmCertificateRequest -SqlInstance "SQL01" -Purpose "SSL" `
        -Subject "CN=SQL01.firma.de,O=Firma GmbH,L=Muenchen,C=DE" `
        -SubjectAlternativeNames @("sql01.firma.de","sql01","192.168.1.10") `
        -KeyLength 4096 -ValidityYears 2

.EXAMPLE
    # CSR with output to a specific directory
    New-sqmCertificateRequest -SqlInstance "SQL01" -CertificateName "TLS_CERT" `
        -OutputPath "D:\CertRequests"

.NOTES
    Requires: dbatools (for instance reading), Invoke-sqmLogging, Get-sqmDefaultOutputPath
    certreq.exe must be available (Windows standard).
    The generated CSR is submitted to the CA. The returned certificate is
    installed with Install-sqmCertificate.
    Private Key: When using certreq.exe, the private key remains in the local
    Windows certificate store (machine store). For SQL Server import it must be
    exported and provided as a .pfx/.pvk file.
#>
function New-sqmCertificateRequest
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$CertificateName,
		[Parameter(Mandatory = $false)]
		[string]$Database = 'master',
		[Parameter(Mandatory = $false)]
		[string]$Subject,
		[Parameter(Mandatory = $false)]
		[string[]]$SubjectAlternativeNames = @(),
		[Parameter(Mandatory = $false)]
		[ValidateSet(2048, 4096)]
		[int]$KeyLength = 2048,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 10)]
		[int]$ValidityYears = 3,
		[Parameter(Mandatory = $false)]
		[ValidateSet('AlwaysOn', 'TDE', 'SSL', 'ServiceBroker', 'UserDefined')]
		[string]$Purpose = 'SSL',
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[string]$Organization,
		[Parameter(Mandatory = $false)]
		[string]$OrganizationalUnit,
		[Parameter(Mandatory = $false)]
		[string]$Locality,
		[Parameter(Mandatory = $false)]
		[string]$State,
		[Parameter(Mandatory = $false)]
		[string]$Country = 'DE',
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
		
		if (-not $OutputPath) { $OutputPath = Join-Path (Get-sqmDefaultOutputPath) 'Cert' }
		
		Invoke-sqmLogging -Message "Starte $functionName auf $SqlInstance" -FunctionName $functionName -Level "INFO"
	}
	
	process
	{
		try
		{
			$datestamp = Get-Date -Format 'yyyyMMdd_HHmsqm'
			$safeInstance = $SqlInstance -replace '\\', '_'
			
			# -------------------------------------------------------------------
			# 1. Bestandszertifikat lesen (wenn angegeben)
			# -------------------------------------------------------------------
			$existingSubject = $null
			$existingIssuer = $null
			$existingExpiry = $null
			$existingPurpose = $Purpose
			$boundEndpointName = $null
			$agListeners = @()
			
			if ($CertificateName)
			{
				if (-not $script:dbatoolsAvailable) { throw "dbatools nicht verfuegbar." }
				
				$connParams = @{
					SqlInstance   = $SqlInstance
					SqlCredential = $SqlCredential
					Database	  = $Database
				}
				
				$certQuery = @"
SELECT c.name, c.subject, c.issuer_name, c.expiry_date, c.start_date
FROM sys.certificates c
WHERE c.name = '$($CertificateName -replace "'", "''")'
"@
				$existingCert = Invoke-DbaQuery @connParams -Query $certQuery -ErrorAction Stop
				if (-not $existingCert) { throw "Zertifikat '$CertificateName' nicht gefunden." }
				
				$existingSubject = $existingCert.subject
				$existingIssuer = $existingCert.issuer_name
				$existingExpiry = $existingCert.expiry_date
				
				# Endpoint-Bindung und Purpose ermitteln
				$epQuery = @"
SELECT e.name AS EndpointName, e.type_desc
FROM sys.endpoints e
INNER JOIN sys.database_mirroring_endpoints dme ON e.endpoint_id = dme.endpoint_id
INNER JOIN sys.certificates c ON dme.certificate_id = c.certificate_id
WHERE c.name = '$($CertificateName -replace "'", "''")'
"@
				$ep = Invoke-DbaQuery @connParams -Database 'master' -Query $epQuery -ErrorAction SilentlyContinue
				if ($ep) { $existingPurpose = 'AlwaysOn'; $boundEndpointName = $ep.EndpointName }
				
				# AG-Listener fuer SANs
				$listenerQuery = @"
SELECT dns_name AS ListenerName FROM sys.availability_group_listeners
"@
				try
				{
					$listeners = Invoke-DbaQuery @connParams -Database 'master' -Query $listenerQuery -ErrorAction SilentlyContinue
					$agListeners = @($listeners | Select-Object -ExpandProperty ListenerName)
				}
				catch { }
				
				Invoke-sqmLogging -Message "Bestandszertifikat gelesen: '$CertificateName', Purpose: $existingPurpose" -FunctionName $functionName -Level "INFO"
			}
			
			# -------------------------------------------------------------------
			# 2. Subject zusammenbauen
			# -------------------------------------------------------------------
			# Vorrang: expliziter Parameter ? aus Bestandszertifikat ? Fallback
			$finalSubject = if ($Subject) { $Subject }
			elseif ($existingSubject) { $existingSubject }
			else
			{
				$fqdn = [System.Net.Dns]::GetHostEntry($SqlInstance).HostName
				$cn = "CN=$fqdn"
				if ($Organization) { $cn += ",O=$Organization" }
				if ($OrganizationalUnit) { $cn += ",OU=$OrganizationalUnit" }
				if ($Locality) { $cn += ",L=$Locality" }
				if ($State) { $cn += ",S=$State" }
				$cn += ",C=$Country"
				$cn
			}
			
			# CN extrahieren fuer SAN-Basis
			$cnValue = if ($finalSubject -match 'CN=([^,]+)') { $Matches[1] }
			else { $SqlInstance }
			
			# -------------------------------------------------------------------
			# 3. SANs zusammenstellen
			# -------------------------------------------------------------------
			$sanList = [System.Collections.Generic.List[string]]::new()
			
			# NetBIOS-Name der Instanz (ohne \Instanzname)
			$netbiosName = ($SqlInstance -split '\\')[0]
			try { $fqdn = [System.Net.Dns]::GetHostEntry($netbiosName).HostName }
			catch { $fqdn = $netbiosName }
			
			foreach ($san in @($cnValue, $fqdn, $netbiosName) + $agListeners + $SubjectAlternativeNames)
			{
				$san = $san.Trim()
				if ($san -and $sanList -notcontains $san) { $sanList.Add($san) }
			}
			
			# -------------------------------------------------------------------
			# 4. Key Usage und EKU je nach Purpose
			# -------------------------------------------------------------------
			$finalPurpose = if ($existingPurpose -ne 'SSL') { $existingPurpose }
			else { $Purpose }
			
			$keyUsage = switch ($finalPurpose)
			{
				'AlwaysOn'     { 'Digital Signature, Key Encipherment' }
				'ServiceBroker' { 'Digital Signature, Key Encipherment' }
				'TDE'          { 'Key Encipherment' }
				'SSL'          { 'Digital Signature, Key Encipherment' }
				default        { 'Digital Signature, Key Encipherment' }
			}
			
			$ekuOids = switch ($finalPurpose)
			{
				'AlwaysOn'     { @('1.3.6.1.5.5.7.3.1') } # Server Auth
				'ServiceBroker' { @('1.3.6.1.5.5.7.3.1') } # Server Auth
				'SSL'          { @('1.3.6.1.5.5.7.3.1', '1.3.6.1.5.5.7.3.2') } # Server + Client Auth
				'TDE'          { @('1.3.6.1.5.5.7.3.1') }
				default        { @('1.3.6.1.5.5.7.3.1') }
			}
			
			# -------------------------------------------------------------------
			# 5. Ausgabeverzeichnis
			# -------------------------------------------------------------------
			$certName = if ($CertificateName) { $CertificateName }
			else { "NEW_CERT" }
			$outDir = Join-Path $OutputPath "CSR_${safeInstance}_${certName}_${datestamp}"
			if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
			
			$infFile = Join-Path $outDir "${certName}.inf"
			$csrFile = Join-Path $outDir "${certName}.csr"
			$sheetFile = Join-Path $outDir "Bestelldatenblatt_${certName}_${datestamp}.txt"
			
			# -------------------------------------------------------------------
			# 6. INF-Datei fuer certreq.exe erstellen
			# -------------------------------------------------------------------
			$sanSection = ''
			$sanIdx = 1
			foreach ($san in $sanList)
			{
				if ($san -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')
				{
					$sanSection += "        ipAddress = $san`r`n"
				}
				else
				{
					$sanSection += "        dns = $san`r`n"
				}
				$sanIdx++
			}
			
			# SAN-Erweiterung nur generieren wenn SANs vorhanden (leeres _continue_ = 0x80070057!)
			$sanExtensionBlock = ''
			if ($sanList.Count -gt 0)
			{
				$sanContinueValue = ($sanList | ForEach-Object {
					if ($_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { "ipaddress=$_&" }
					else { "dns=$_&" }
				}) -join ''
				$sanContinueValue = $sanContinueValue.TrimEnd('&')

				$sanExtensionBlock = @"

[Extensions]
2.5.29.17 = "{text}"
_continue_ = "$sanContinueValue"
"@
			}

			$infContent = @"
[Version]
Signature = "`$Windows NT`$"

[NewRequest]
Subject                = "$finalSubject"
KeySpec                = 1
KeyLength              = $KeyLength
Exportable             = TRUE
MachineKeySet          = TRUE
SMIME                  = FALSE
PrivateKeyArchive      = FALSE
UserProtected          = FALSE
UseExistingKeySet      = FALSE
ProviderName           = "Microsoft RSA SChannel Cryptographic Provider"
ProviderType           = 12
RequestType            = PKCS10
KeyUsage               = 0xa0
HashAlgorithm          = SHA256

[EnhancedKeyUsageExtension]
OID = $($ekuOids -join "`r`nOID = ")
$sanExtensionBlock
"@
			
			$infContent | Out-File -FilePath $infFile -Encoding ASCII -Force
			Invoke-sqmLogging -Message "INF-Datei erstellt: $infFile" -FunctionName $functionName -Level "INFO"
			
			# -------------------------------------------------------------------
			# 7. CSR via certreq.exe generieren
			# -------------------------------------------------------------------
			$csrGenerated = $false
			$certreqPath = "$env:SystemRoot\System32\certreq.exe"
			
			if ($PSCmdlet.ShouldProcess($SqlInstance, "CSR erstellen via certreq.exe"))
			{
				if (Test-Path $certreqPath)
				{
					try
					{
						$certreqArgs = @('-new', '-f', $infFile, $csrFile)
						$proc = Start-Process -FilePath $certreqPath -ArgumentList $certreqArgs `
											  -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$outDir\certreq.log" `
											  -RedirectStandardError "$outDir\certreq_err.log"
						
						if ($proc.ExitCode -eq 0 -and (Test-Path $csrFile))
						{
							$csrGenerated = $true
							Invoke-sqmLogging -Message "CSR erfolgreich erstellt: $csrFile" -FunctionName $functionName -Level "INFO"
						}
						else
						{
							$errLog = if (Test-Path "$outDir\certreq_err.log") { Get-Content "$outDir\certreq_err.log" -Raw }
							else { 'n/a' }
							Invoke-sqmLogging -Message "certreq.exe Fehler (ExitCode $($proc.ExitCode)): $errLog" -FunctionName $functionName -Level "WARNING"
						}
					}
					catch
					{
						Invoke-sqmLogging -Message "certreq.exe Ausfuehrung fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
					}
				}
				else
				{
					Invoke-sqmLogging -Message "certreq.exe nicht gefunden - CSR muss manuell erstellt werden." -FunctionName $functionName -Level "WARNING"
				}
			}
			
			# -------------------------------------------------------------------
			# 8. Bestelldatenblatt schreiben
			# -------------------------------------------------------------------
			$lines = [System.Collections.Generic.List[string]]::new()
			
			$lines.Add("=" * 70)
			$lines.Add("  ZERTIFIKAT-BESTELLDATENBLATT")
			$lines.Add("  Erstellt    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
			$lines.Add("  SQL Instanz : $SqlInstance")
			$lines.Add("  Verwendung  : $finalPurpose")
			$lines.Add("=" * 70)
			$lines.Add("")
			
			if ($CertificateName -and $existingCert)
			{
				$lines.Add("BESTEHENDES ZERTIFIKAT (VORLAGE)")
				$lines.Add("-" * 40)
				$lines.Add("  Name         : $CertificateName")
				$lines.Add("  Subject      : $existingSubject")
				$lines.Add("  Aussteller   : $existingIssuer")
				$lines.Add("  Laeuft ab     : $(if ($existingExpiry) { $existingExpiry.ToString('yyyy-MM-dd') }
						else { 'n/a' })")
				if ($boundEndpointName) { $lines.Add("  Endpoint     : $boundEndpointName") }
				$lines.Add("")
			}
			
			$lines.Add("ANGABEN FueR CA-BESTELLUNG")
			$lines.Add("-" * 40)
			$lines.Add("  Subject (DN) : $finalSubject")
			$lines.Add("  Key Length   : $KeyLength Bit")
			$lines.Add("  Hash Algo    : SHA-256")
			$lines.Add("  Laufzeit     : $ValidityYears Jahr(e) (Entscheidung liegt bei der CA)")
			$lines.Add("  Key Usage    : $keyUsage")
			$lines.Add("  EKU OIDs     : $($ekuOids -join ', ')")
			$lines.Add("  Zertifikatstyp: $(switch ($finalPurpose)
					{
						'AlwaysOn'     { 'Server-Authentifizierung (intern)' }
						'SSL'          { 'SSL/TLS Server-Zertifikat' }
						'ServiceBroker' { 'Server-Authentifizierung (intern)' }
						'TDE'          { 'Schluesselverschluesselung (intern)' }
						default        { 'Server-Authentifizierung' }
					})")
			$lines.Add("")
			$lines.Add("  SUBJECT ALTERNATIVE NAMES (SANs):")
			foreach ($san in $sanList)
			{
				$type = if ($san -match '^\d') { 'IP' }
				else { 'DNS' }
				$lines.Add("    $type : $san")
			}
			$lines.Add("")
			
			$lines.Add("CSR-DATEI")
			$lines.Add("-" * 40)
			if ($csrGenerated)
			{
				$lines.Add("  Datei        : $csrFile")
				$lines.Add("  Status       : Erstellt - bei der CA einreichen")
				$lines.Add("")
				$lines.Add("  CSR-INHALT (fuer Web-Einreichung kopieren):")
				$lines.Add("  " + "-" * 60)
				$csrContent = Get-Content $csrFile -Raw -ErrorAction SilentlyContinue
				if ($csrContent) { $lines.Add($csrContent) }
				$lines.Add("  " + "-" * 60)
			}
			else
			{
				$lines.Add("  CSR konnte nicht automatisch erstellt werden.")
				$lines.Add("  INF-Datei    : $infFile")
				$lines.Add("  Manuell ausfuehren:")
				$lines.Add("    certreq.exe -new -f `"$infFile`" `"$csrFile`"")
			}
			$lines.Add("")
			
			$lines.Add("CHECKLISTE CA-BESTELLUNG")
			$lines.Add("-" * 40)
			$lines.Add("  [ ] CSR-Datei bei CA eingereicht: $csrFile")
			$lines.Add("  [ ] Alle SANs in der Bestellung angegeben (oben vollstaendig?)")
			$lines.Add("  [ ] Laufzeit angegeben: $ValidityYears Jahr(e)")
			$lines.Add("  [ ] Zertifikatstyp korrekt gewaehlt (s.o.)")
			$lines.Add("  [ ] Ansprechpartner / Kostenstelle angegeben")
			$lines.Add("  [ ] Rueckgabeformat vereinbart: PFX (inkl. Private Key) oder CER+PVK")
			$lines.Add("  [ ] Zertifikat von CA erhalten")
			$lines.Add("  [ ] Zertifikat installiert via: Install-sqmCertificate")
			$lines.Add("")
			
			$lines.Add("NACH ERHALT DES ZERTIFIKATS")
			$lines.Add("-" * 40)
			$lines.Add("  # PFX-Import (CA liefert PFX mit Private Key):")
			$lines.Add("  Install-sqmCertificate -SqlInstance '$SqlInstance' \")
			$lines.Add("      -CertFile 'C:\Certs\neues_zert.pfx' \")
			$lines.Add("      -CertPassword (Read-Host -AsSecureString) \")
			$lines.Add("      -Purpose '$finalPurpose'$(if ($boundEndpointName) { " -EndpointName '$boundEndpointName'" })")
			$lines.Add("")
			$lines.Add("  # CER+PVK-Import (CA liefert separat):")
			$lines.Add("  Install-sqmCertificate -SqlInstance '$SqlInstance' \")
			$lines.Add("      -CertFile 'C:\Certs\neues_zert.cer' \")
			$lines.Add("      -PrivateKeyFile 'C:\Certs\neues_zert.pvk' \")
			$lines.Add("      -CertPassword (Read-Host -AsSecureString) \")
			$lines.Add("      -Purpose '$finalPurpose'$(if ($boundEndpointName) { " -EndpointName '$boundEndpointName'" })")
			$lines.Add("")
			
			$lines.Add("GESPEICHERTE DATEIEN")
			$lines.Add("-" * 40)
			$lines.Add("  Verzeichnis  : $outDir")
			$lines.Add("  INF-Datei    : $infFile")
			if ($csrGenerated) { $lines.Add("  CSR-Datei    : $csrFile") }
			$lines.Add("  Datenblatt   : $sheetFile")
			
			$lines | Out-File -FilePath $sheetFile -Encoding UTF8 -Force
			Invoke-sqmLogging -Message "Bestelldatenblatt: $sheetFile" -FunctionName $functionName -Level "INFO"
			
			Copy-sqmToCentralPath -Path @($sheetFile)
			if ($csrGenerated) { Copy-sqmToCentralPath -Path @($csrFile) }
			
			# -------------------------------------------------------------------
			# 9. Rueckgabeobjekt
			# -------------------------------------------------------------------
			$result = [PSCustomObject]@{
				SqlInstance	     = $SqlInstance
				ExistingCertName = $CertificateName
				Subject		     = $finalSubject
				SubjectAltNames  = $sanList.ToArray()
				Purpose		     = $finalPurpose
				KeyLength	     = $KeyLength
				ValidityYears    = $ValidityYears
				OutputDirectory  = $outDir
				InfFile		     = $infFile
				CsrFile		     = if ($csrGenerated) { $csrFile } else { $null }
				CsrGenerated	 = $csrGenerated
				OrderSheetFile   = $sheetFile
				NextStep		 = if ($csrGenerated) { "CSR bei CA einreichen: $csrFile" } else { "CSR manuell erstellen: certreq.exe -new -f `"$infFile`" `"$csrFile`"" }
			}
			
			Write-Host "Bestelldatenblatt erstellt: $sheetFile" -ForegroundColor Green
			if ($csrGenerated) { Write-Host "CSR-Datei bereit:           $csrFile" -ForegroundColor Cyan }
			else { Write-Warning "CSR konnte nicht automatisch erstellt werden. INF-Datei: $infFile" }
			
			return $result
		}
		catch
		{
			$errMsg = "Fehler bei CSR-Erstellung: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			if ($EnableException) { throw }
			Write-Error $errMsg
			return $null
		}
	}
	
	end
	{
		Invoke-sqmLogging -Message "$functionName abgeschlossen." -FunctionName $functionName -Level "INFO"
	}
}