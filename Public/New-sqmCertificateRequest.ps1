<#
.SYNOPSIS
    Erstellt eine CSR (Certificate Signing Request) und ein Bestelldatenblatt fuer ein
    CA-signiertes Zertifikat auf Basis eines bestehenden SQL Server-Zertifikats.

.DESCRIPTION
    Liest alle relevanten Eigenschaften des bestehenden Zertifikats aus SQL Server
    (Subject, SANs, Verwendungszweck, Endpoint-Bindung) und erstellt:

    1. INF-Datei (certreq-Konfiguration) mit allen Feldern aus dem Bestandszertifikat
    2. CSR-Datei (.csr / PKCS#10) via Windows certreq.exe oder New-SelfSignedCertificate
    3. Bestelldatenblatt (.txt) mit:
         - Allen Angaben fuer die CA-Bestellung (Subject, SANs, Key Usage, EKU)
         - Vorgeschlagenem Zertifikatstyp je nach Verwendungszweck
         - Checkliste fuer den Bestellprozess
         - T-SQL-Befehlen fuer die spaetere Installation
    4. Optional: Privaten Schluessel lokal erzeugen und sicher speichern

    VERWENDUNGSZWECK-SPEZIFISCHE BEHANDLUNG:
      AlwaysOn / Mirroring  ? Key Usage: Digital Signature, Key Encipherment
                               EKU: Server Authentication (1.3.6.1.5.5.7.3.1)
      TDE                   ? Hinweis: TDE nutzt ueblicherweise selbstsignierte Zertifikate;
                               CA-signierte Zertifikate sind moeglich aber unueblich
      SSL/TLS Verbindungen  ? Key Usage: Digital Signature, Key Encipherment
                               EKU: Server Authentication + Client Authentication
      Service Broker        ? Key Usage: Digital Signature, Key Encipherment

.PARAMETER SqlInstance
    SQL Server-Instanz (Standard: aktueller Computername). Wird fuer SAN und Bestellblatt verwendet.

.PARAMETER SqlCredential
    PSCredential fuer die Verbindung.

.PARAMETER CertificateName
    Name des bestehenden Zertifikats als Vorlage. Wenn nicht angegeben, wird ein
    neues Zertifikat ohne Vorlage erstellt (-Subject wird dann Pflicht).

.PARAMETER Database
    Datenbank in der das Zertifikat liegt. Standard: master.

.PARAMETER Subject
    Subject (CN) des neuen Zertifikats. ueberschreibt den Wert aus dem Bestandszertifikat.
    Format: CN=SQL01.domain.com,O=Firma,L=Stadt,S=Bundesland,C=DE

.PARAMETER SubjectAlternativeNames
    Zusaetzliche SANs (DNS-Namen oder IP-Adressen).
    Wird automatisch ergaenzt um: FQDN, NetBIOS-Name, AG-Listener (falls erkannt).

.PARAMETER KeyLength
    Schluessellaenge in Bit. Standard: 2048. Fuer neue Installationen empfohlen: 4096.

.PARAMETER ValidityYears
    Gewuenschte Laufzeit in Jahren (Information fuer die CA, keine Garantie). Standard: 3.

.PARAMETER Purpose
    Verwendungszweck wenn kein bestehendes Zertifikat als Vorlage verwendet wird.
    Gueltige Werte: AlwaysOn, TDE, SSL, ServiceBroker, UserDefined.

.PARAMETER OutputPath
    Ausgabeverzeichnis fuer CSR, INF und Bestelldatenblatt. Standard: C:\System\WinSrvLog\MSSQL\Cert

.PARAMETER Organization
    Organisationsname fuer das Zertifikat (O=). Standard: aus bestehendem Zertifikat oder Computername.

.PARAMETER OrganizationalUnit
    Organisationseinheit (OU=). Optional.

.PARAMETER Locality
    Ort (L=). Optional.

.PARAMETER State
    Bundesland/Staat (S=). Optional.

.PARAMETER Country
    Laenderkennzeichen zweistellig (C=). Standard: DE.

.PARAMETER EnableException
    Ausnahmen sofort ausloesen.

.EXAMPLE
    # CSR auf Basis eines bestehenden Zertifikats
    New-sqmCertificateRequest -SqlInstance "SQL01" -CertificateName "AG_CERT"

.EXAMPLE
    # Neuer CSR ohne Vorlage, alle Felder manuell
    New-sqmCertificateRequest -SqlInstance "SQL01" -Purpose "SSL" `
        -Subject "CN=SQL01.firma.de,O=Firma GmbH,L=Muenchen,C=DE" `
        -SubjectAlternativeNames @("sql01.firma.de","sql01","192.168.1.10") `
        -KeyLength 4096 -ValidityYears 2

.EXAMPLE
    # CSR mit Ausgabe in bestimmtes Verzeichnis
    New-sqmCertificateRequest -SqlInstance "SQL01" -CertificateName "TLS_CERT" `
        -OutputPath "D:\CertRequests"

.NOTES
    Erfordert: dbatools (fuer Instanz-Lesen), Invoke-sqmLogging, Get-sqmDefaultOutputPath
    certreq.exe muss verfuegbar sein (Windows-Standard).
    Der erzeugte CSR wird bei der CA eingereicht. Das zurueckgelieferte Zertifikat
    wird mit Install-sqmCertificate installiert.
    Private Key: Beim Einsatz von certreq.exe verbleibt der Private Key im lokalen
    Windows Zertifikatspeicher (Maschinen-Store). Fuer SQL Server-Import muss er
    exportiert und als .pfx/.pvk bereitgestellt werden.
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

[Extensions]
2.5.29.17 = "{text}"
_continue_ = $($sanList | ForEach-Object {
					if ($_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { "ipaddress=$_&" }
					else { "dns=$_&" }
				} | Out-String | ForEach-Object { $_.TrimEnd() -replace "&`r`n$", "" })
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