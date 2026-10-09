# =============================================================================
# SSRS REST API v2.0 - gemeinsame Zugriffsschicht
# =============================================================================
# Bewusst REST statt SOAP (ReportService2010.asmx): New-WebServiceProxy gibt es unter
# PowerShell 7 nicht mehr, die REST-API laeuft unter 5.1 und 7 gleich.

# Macht aus jeder ueblichen Schreibweise die Basis-URL der REST-API:
#   SRV                              -> http://SRV/Reports/api/v2.0
#   https://srv:8443                 -> https://srv:8443/Reports/api/v2.0
#   http://srv/ReportServer          -> http://srv/Reports/api/v2.0
#   http://srv/ReportServer_INST2    -> http://srv/Reports_INST2/api/v2.0
#   http://srv/Reports/api/v2.0      -> unveraendert
# Eigene virtuelle Verzeichnisse: einfach die vollstaendige .../api/v2.0-URL angeben.
function ConvertTo-sqmSsrsApiBase
{
	[CmdletBinding()]
	[OutputType([string])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$ReportServer
	)

	$url = $ReportServer.Trim().TrimEnd('/')
	if ($url -notmatch '^[a-z]+://') { $url = "http://$url" }
	if ($url -match '/api/v2\.0$') { return $url }

	$uri = [System.Uri]$url
	$path = $uri.AbsolutePath.TrimEnd('/')
	if ([string]::IsNullOrEmpty($path))
	{
		$path = '/Reports'
	}
	elseif ($path -match '(?i)/ReportServer(_[^/]+)?$')
	{
		$path = $path -replace '(?i)/ReportServer(_[^/]+)?$', '/Reports$1'
	}

	$base = $uri.GetLeftPart([System.UriPartial]::Authority)
	return "$base$path/api/v2.0"
}

# OData-Schluessel fuer Pfadzugriffe: CatalogItems(Path='/a/b c') - Hochkomma verdoppelt,
# alles ausser '/' URL-kodiert (ein kodierter Schraegstrich wird von HTTP.sys abgewiesen).
function ConvertTo-sqmSsrsPathKey
{
	[CmdletBinding()]
	[OutputType([string])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$Path
	)
	$escaped = [System.Uri]::EscapeDataString($Path.Replace("'", "''")) -replace '%2F', '/'
	return "(Path='$escaped')"
}

# Ein REST-Aufruf. Liefert das geparste JSON (bzw. mit -OutFile nichts).
# Fehler werfen eine Exception mit Data['StatusCode'] und dem Antworttext des Servers -
# der Antworttext ist bei SSRS meist die einzige brauchbare Fehlerbeschreibung.
function Invoke-sqmSsrsRest
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]$Uri,

		[Parameter(Mandatory = $false)]
		[ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
		[string]$Method = 'GET',

		[Parameter(Mandatory = $false)]
		[object]$Body,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$Credential,

		[Parameter(Mandatory = $false)]
		[string]$OutFile,

		[Parameter(Mandatory = $false)]
		[switch]$SkipCertificateCheck
	)

	$p = @{
		Uri             = $Uri
		Method          = $Method
		UseBasicParsing = $true
		Headers         = @{ Accept = 'application/json' }
	}
	if ($Credential) { $p['Credential'] = $Credential } else { $p['UseDefaultCredentials'] = $true }
	if ($OutFile) { $p['OutFile'] = $OutFile }
	# PowerShell 7 verweigert jede Anmeldung ueber http:// ohne diesen Schalter - auch die
	# Windows-Anmeldung (NTLM/Kerberos), die gar kein Klartextkennwort sendet. Viele Report
	# Server laufen intern ohne TLS; 5.1 kennt den Parameter nicht.
	if ($PSVersionTable.PSVersion.Major -ge 6 -and $Uri -match '^http://') { $p['AllowUnencryptedAuthentication'] = $true }

	if ($null -ne $Body)
	{
		# Als UTF-8-Bytes senden: Windows PowerShell 5.1 kodiert einen String-Body sonst nicht
		# als UTF-8, Umlaute in Namen und Verbindungszeichenfolgen kaemen verstuemmelt an.
		$json = $Body
		if ($Body -isnot [string]) { $json = ConvertTo-Json -InputObject $Body -Depth 15 -Compress }
		$p['Body'] = [System.Text.Encoding]::UTF8.GetBytes($json)
		$p['ContentType'] = 'application/json; charset=utf-8'
	}

	$restoreCallback = $false
	$oldCallback = $null
	if ($SkipCertificateCheck)
	{
		if ($PSVersionTable.PSVersion.Major -ge 6)
		{
			$p['SkipCertificateCheck'] = $true
		}
		else
		{
			$oldCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
			[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
			$restoreCallback = $true
		}
	}

	try
	{
		if ($OutFile)
		{
			$null = Invoke-WebRequest @p -ErrorAction Stop
			return
		}
		return (Invoke-RestMethod @p -ErrorAction Stop)
	}
	catch
	{
		$status = $null
		$detail = ''
		$resp = $_.Exception.Response
		if ($resp)
		{
			try { $status = [int]$resp.StatusCode } catch { }
		}
		# PS 7 legt den Antworttext in ErrorDetails ab, 5.1 nur im Response-Stream.
		if ($_.ErrorDetails -and $_.ErrorDetails.Message)
		{
			$detail = $_.ErrorDetails.Message
		}
		elseif ($resp -and ($resp | Get-Member -Name GetResponseStream -MemberType Method))
		{
			try
			{
				$stream = $resp.GetResponseStream()
				if ($stream.CanSeek) { $stream.Position = 0 }
				$reader = New-Object System.IO.StreamReader($stream)
				$detail = $reader.ReadToEnd()
				$reader.Dispose()
			}
			catch { }
		}
		# SSRS antwortet mit {"error":{"code":..,"message":..}} - nur die Meldung ist lesbar.
		if ($detail -match '"message"\s*:\s*"((?:[^"\\]|\\.)*)"') { $detail = $Matches[1] -replace '\\"', '"' }

		$msg = "$Method $Uri"
		if ($status) { $msg += " -> HTTP $status" }
		$msg += ": $($_.Exception.Message)"
		if ($detail) { $msg += " | $detail" }
		$ex = New-Object System.Exception($msg, $_.Exception)
		$ex.Data['StatusCode'] = $status
		throw $ex
	}
	finally
	{
		if ($restoreCallback) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback }
	}
}
