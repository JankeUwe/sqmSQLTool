<#
.SYNOPSIS
    Findet unverschluesselte Verbindungen zu SQL Server und die Instanzen, die sie annehmen.

.DESCRIPTION
    Beantwortet zwei Fragen in einem Lauf:

    1. Welche Instanzen NEHMEN unverschluesselte Verbindungen an?
       Liest ForceEncryption (und ab SQL Server 2022 ForceStrictEncryption) aus
       sys.dm_server_registry. ForceEncryption = 0 heisst: der Client entscheidet, ob
       verschluesselt wird; eine Anwendung ohne Encrypt=True verbindet unverschluesselt.
       Unter Linux liefert die Sicht keine Zeilen, der Wert ist dort 'Unbekannt' (mssql.conf,
       network.forceencryption). Ist er unbekannt und wurde trotzdem eine unverschluesselte
       Remote-Verbindung beobachtet, gilt die Instanz als annehmend (Beweis durch Beobachtung).

    2. WER verbindet gerade unverschluesselt?
       Liest sys.dm_exec_connections (encrypt_option = 'FALSE') zusammen mit
       sys.dm_exec_sessions und fasst gleiche Verbindungen zusammen (Login, Host, Programm,
       Client-Adresse, Transport, Authentifizierung) mit Anzahl und aeltester Anmeldezeit.
       Die eigene Session des Aufrufers und MARS-Teilsessions werden nicht gezaehlt.

    Einstufung je Verbindung:
    - Warning : Remote (TCP von einer fremden Adresse oder Named Pipe) und unverschluesselt
    - Info    : lokal (Shared Memory, Loopback oder eigene Adresse); nur mit -IncludeLocal.
                Shared Memory ist nie verschluesselt und kein Befund.

    Einstufung je Instanz: Warning, wenn sie unverschluesselte Verbindungen annimmt
    (ForceEncryption = 0) UND aktuell Remote-Verbindungen unverschluesselt laufen; Info, wenn sie
    sie nur annimmt, aber aktuell keine laeuft; OK bei ForceEncryption = 1 und ohne Verbindungen.

    Grenze: Die Sichten zeigen nur die JETZT offenen Verbindungen. Ein Client, der heute Nacht
    unverschluesselt war und jetzt nicht verbunden ist, taucht nicht auf. Mehrfach zu
    unterschiedlichen Zeiten ausfuehren, bevor ForceEncryption eingeschaltet wird.

    Ausgabe: Objekte (je zusammengefasster Verbindung, oder je Instanz mit -InstanceSummary)
    und ein Bericht (HTML/TXT/CSV) im Unterverzeichnis UnencryptedConnections.

.PARAMETER SqlInstance
    SQL Server-Instanz(en). Pipeline-faehig. Standard: aktueller Computername.

.PARAMETER SqlCredential
    Optionales PSCredential.

.PARAMETER IncludeLocal
    Auch lokale Verbindungen (Loopback, eigene Adresse) ausgeben. Shared Memory bleibt immer
    ausgeblendet.

.PARAMETER InstanceSummary
    Gibt je Instanz ein Objekt zurueck (ForceEncryption, nimmt unverschluesselt an, Anzahl
    Remote-Verbindungen) statt je Verbindung.

.PARAMETER OutputPath
    Ausgabeverzeichnis fuer den Bericht (HTML/TXT/CSV).
    Standard: <Modul-Standardpfad>\UnencryptedConnections.

.PARAMETER ContinueOnError
    Bei Fehler auf einer Instanz mit der naechsten fortfahren.

.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen.

.PARAMETER NoOpen
    Bericht nach dem Erstellen NICHT automatisch oeffnen.

.PARAMETER Confirm
    Vor dem Schreiben der Berichtsdateien nachfragen.

.PARAMETER WhatIf
    Zeigt, welche Berichtsdateien erstellt wuerden, ohne sie zu schreiben.

.EXAMPLE
    Get-sqmUnencryptedConnection -SqlInstance SQL01

    Zeigt, wer sich gerade unverschluesselt mit SQL01 verbindet, und ob SQL01 das zulaesst.

.EXAMPLE
    Get-sqmUnencryptedConnection -SqlInstance SQL01, SQL02 -InstanceSummary | Where-Object AcceptsUnencrypted

    Nur die Instanzen, die unverschluesselte Verbindungen annehmen.

.EXAMPLE
    Get-sqmUnencryptedConnection -SqlInstance SQL01 -NoOpen | Group-Object ProgramName | Sort-Object Count -Descending

    Welche Anwendungen verbinden unverschluesselt?

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging
    Rechte: VIEW SERVER STATE (ab SQL Server 2022 reicht VIEW SERVER PERFORMANCE STATE). Ohne
    dieses Recht sieht der Login nur seine eigene Verbindung; das Ergebnis waere "keine
    unverschluesselten Verbindungen", obwohl welche existieren. Die Funktion erkennt das
    (PermissionOk = $false, Warnung) und meldet dann nichts als sauber.
    Abhilfe: Zertifikat binden und ForceEncryption setzen mit Set-sqmSqlTlsCertificate,
    Zustand der Instanzen mit Get-sqmTlsStatus.
#>
function Get-sqmUnencryptedConnection
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$IncludeLocal,

		[Parameter(Mandatory = $false)]
		[switch]$InstanceSummary,

		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'UnencryptedConnections'),

		[Parameter(Mandatory = $false)]
		[switch]$ContinueOnError,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException,

		[Parameter(Mandatory = $false)]
		[switch]$NoOpen
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$connResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		$instResults = [System.Collections.Generic.List[PSCustomObject]]::new()

		# ForceEncryption steht als sql_variant in sys.dm_server_registry; als Text holen, in PowerShell auswerten.
		# Rechtepruefung: VIEW SERVER PERFORMANCE STATE gibt es erst ab 2022 (auf aelteren Versionen NULL).
		$instanceQuery = @"
SELECT
    CAST(SERVERPROPERTY('ServerName') AS nvarchar(256)) AS ServerName,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)) AS ProductVersion,
    (SELECT TOP (1) CAST(value_data AS nvarchar(256)) FROM sys.dm_server_registry
      WHERE registry_key LIKE N'%SuperSocketNetLib' AND value_name = N'ForceEncryption') AS ForceEncryption,
    (SELECT TOP (1) CAST(value_data AS nvarchar(256)) FROM sys.dm_server_registry
      WHERE registry_key LIKE N'%SuperSocketNetLib' AND value_name = N'ForceStrictEncryption') AS ForceStrictEncryption,
    (SELECT COUNT(*) FROM sys.dm_server_registry
      WHERE registry_key LIKE N'%SuperSocketNetLib' AND value_name = N'ForceEncryption') AS RegistryRows,
    ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER PERFORMANCE STATE'),
           HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE')) AS HasViewServerState
"@

		# 'Session' = MARS-Teilsession auf einer bereits gezaehlten physischen Verbindung.
		$connQuery = @"
SELECT
    c.session_id            AS SessionId,
    c.net_transport         AS NetTransport,
    c.auth_scheme           AS AuthScheme,
    c.client_net_address    AS ClientAddress,
    c.local_net_address     AS LocalAddress,
    s.login_name            AS LoginName,
    s.host_name             AS HostName,
    s.program_name          AS ProgramName,
    s.login_time            AS LoginTime
FROM sys.dm_exec_connections c
LEFT JOIN sys.dm_exec_sessions s ON s.session_id = c.session_id
WHERE c.encrypt_option = 'FALSE'
  AND c.net_transport <> 'Session'
  AND c.session_id <> @@SPID
"@

		$nullToText = {
			param ($v)
			if ($null -eq $v -or $v -is [DBNull]) { '' } else { [string]$v }
		}

		Invoke-sqmLogging -Message "Starte $functionName" -FunctionName $functionName -Level 'INFO'
	}

	process
	{
		foreach ($instance in $SqlInstance)
		{
			try
			{
				$connParams = @{ SqlInstance = $instance }
				if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

				$inst = @(Invoke-DbaQuery @connParams -Query $instanceQuery -As PSObject -EnableException) | Select-Object -First 1
				$rows = @(Invoke-DbaQuery @connParams -Query $connQuery -As PSObject -EnableException)

				$permOk = ($inst.HasViewServerState -is [DBNull]) -or ($null -eq $inst.HasViewServerState) -or ([int]$inst.HasViewServerState -eq 1)
				if (-not $permOk)
				{
					Write-Warning "[$instance] Dem Login fehlt VIEW SERVER STATE - das Ergebnis ist nicht belastbar (nur die eigene Verbindung ist sichtbar)."
					Invoke-sqmLogging -Message "[$instance] VIEW SERVER STATE fehlt, Ergebnis nicht belastbar." -FunctionName $functionName -Level 'WARNING'
				}

				# ForceEncryption: '1'/'0' aus der Registry-Sicht; ohne Zeilen (Linux) unbekannt.
				$feText = & $nullToText $inst.ForceEncryption
				$strictText = & $nullToText $inst.ForceStrictEncryption
				$forceEnc = if ($feText -ne '') { $feText -eq '1' } else { $null }
				$forceStrict = if ($strictText -ne '') { $strictText -eq '1' } else { $null }

				# Verbindungen klassifizieren
				$classified = foreach ($r in $rows)
				{
					$transport = & $nullToText $r.NetTransport
					$client = & $nullToText $r.ClientAddress
					$local = & $nullToText $r.LocalAddress
					$isShared = $transport -eq 'Shared memory'
					$isLocal = $isShared -or ($client -in @('127.0.0.1', '::1')) -or ($client -ne '' -and $client -eq $local)
					[PSCustomObject]@{
						SessionId     = [int]$r.SessionId
						NetTransport  = $transport
						AuthScheme    = & $nullToText $r.AuthScheme
						ClientAddress = $client
						LoginName     = & $nullToText $r.LoginName
						HostName      = & $nullToText $r.HostName
						ProgramName   = & $nullToText $r.ProgramName
						LoginTime     = if ($r.LoginTime -is [DBNull]) { $null } else { $r.LoginTime }
						IsShared      = $isShared
						IsLocal       = $isLocal
					}
				}
				$classified = @($classified)
				$remote = @($classified | Where-Object { -not $_.IsLocal })
				$shown = if ($IncludeLocal) { @($classified | Where-Object { -not $_.IsShared }) } else { $remote }

				# Instanz nimmt an: Konfiguration, sonst Beobachtung
				$accepts = if ($forceStrict -eq $true -or $forceEnc -eq $true) { $false }
				elseif ($forceEnc -eq $false) { $true }
				elseif ($remote.Count -gt 0) { $true }
				else { $null }

				$instRisk = if ($accepts -and $remote.Count -gt 0) { 'Warning' }
				elseif ($accepts) { 'Info' }
				elseif ($null -eq $accepts) { 'Unknown' }
				else { 'OK' }

				$instHint = if (-not $permOk) { 'VIEW SERVER STATE fehlt: Ergebnis nicht belastbar' }
				elseif ($accepts -and $remote.Count -gt 0) { 'Clients pruefen (Encrypt=True), dann ForceEncryption setzen (Set-sqmSqlTlsCertificate)' }
				elseif ($accepts) { 'Keine Remote-Verbindung unverschluesselt im Moment; ForceEncryption = 0 laesst sie zu' }
				elseif ($null -eq $accepts) { 'ForceEncryption nicht lesbar (Linux?), keine Remote-Verbindung unverschluesselt im Moment' }
				else { 'ForceEncryption aktiv' }

				$instResults.Add([PSCustomObject]@{
					SqlInstance             = $instance
					ServerName              = & $nullToText $inst.ServerName
					ProductVersion          = & $nullToText $inst.ProductVersion
					ForceEncryption         = $forceEnc
					ForceStrictEncryption   = $forceStrict
					AcceptsUnencrypted      = $accepts
					UnencryptedRemote       = $remote.Count
					UnencryptedLocal        = @($classified | Where-Object { $_.IsLocal -and -not $_.IsShared }).Count
					PermissionOk            = $permOk
					RiskLevel               = $instRisk
					Hint                    = $instHint
				})

				# Zusammenfassen
				$groups = $shown | Group-Object LoginName, HostName, ProgramName, ClientAddress, NetTransport, AuthScheme
				foreach ($g in $groups)
				{
					$first = $g.Group[0]
					$times = @($g.Group | Where-Object { $null -ne $_.LoginTime } | ForEach-Object { $_.LoginTime })
					$ids = @($g.Group | ForEach-Object { $_.SessionId } | Sort-Object)
					$idText = ($ids | Select-Object -First 20) -join ','
					if ($ids.Count -gt 20) { $idText += ',...' }
					$connResults.Add([PSCustomObject]@{
						SqlInstance        = $instance
						RiskLevel          = if ($first.IsLocal) { 'Info' } else { 'Warning' }
						Scope              = if ($first.IsLocal) { 'Lokal' } else { 'Remote' }
						LoginName          = $first.LoginName
						HostName           = $first.HostName
						ProgramName        = $first.ProgramName
						ClientAddress      = $first.ClientAddress
						NetTransport       = $first.NetTransport
						AuthScheme         = $first.AuthScheme
						ConnectionCount    = $g.Count
						OldestLogin        = if ($times.Count -gt 0) { ($times | Measure-Object -Minimum).Minimum } else { $null }
						SessionIds         = $idText
						AcceptsUnencrypted = $accepts
						ForceEncryption    = $forceEnc
					})
				}

				Invoke-sqmLogging -Message "[$instance] ForceEncryption=$feText, unverschluesselt remote=$($remote.Count), lokal=$(@($classified | Where-Object { $_.IsLocal -and -not $_.IsShared }).Count)." -FunctionName $functionName -Level 'INFO'
			}
			catch
			{
				Invoke-sqmLogging -Message "[$instance] Fehler: $($_.Exception.Message)" -FunctionName $functionName -Level 'ERROR'
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}

	end
	{
		if ($instResults.Count -gt 0)
		{
			$instanceList = $SqlInstance -join ', '
			$cntAccept = @($instResults | Where-Object { $_.AcceptsUnencrypted -eq $true }).Count
			$cntWarn = @($instResults | Where-Object RiskLevel -eq 'Warning').Count
			$cntRemote = ($instResults | Measure-Object -Property UnencryptedRemote -Sum).Sum

			if ($PSCmdlet.ShouldProcess($instanceList, "Erstelle Bericht in $OutputPath"))
			{
				try
				{
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
					}
					$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
					$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
					$safeInst = ($SqlInstance -join '_') -replace '[\\/:*?"<>|,]', '_'
					if ($safeInst.Length -gt 60) { $safeInst = $safeInst.Substring(0, 60) }
					$txtFile = Join-Path $OutputPath "UnencryptedConnections_${safeInst}_${stamp}.txt"
					$csvFile = Join-Path $OutputPath "UnencryptedConnections_${safeInst}_${stamp}.csv"
					$htmlFile = Join-Path $OutputPath "UnencryptedConnections_${safeInst}_${stamp}.html"

					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add('# ================================================================')
					$lines.Add('# sqmSQLTool - Unverschluesselte Verbindungen')
					$lines.Add("# $(Get-sqmReportReference)")
					$lines.Add("# Instanz(en): $instanceList")
					$lines.Add("# Erstellt   : $timestamp")
					$lines.Add("# Nehmen unverschluesselt an: $cntAccept von $($instResults.Count)")
					$lines.Add("# Unverschluesselte Remote-Verbindungen jetzt: $cntRemote")
					$lines.Add('# Momentaufnahme: nur aktuell offene Verbindungen')
					$lines.Add('# ================================================================')
					$lines.Add('')
					$lines.Add('# INSTANZEN')
					foreach ($i in $instResults)
					{
						$lines.Add(("  [{0}] {1}  ForceEncryption={2}  Strict={3}  nimmt an={4}  remote={5}  lokal={6}" -f $i.RiskLevel, $i.SqlInstance, $i.ForceEncryption, $i.ForceStrictEncryption, $i.AcceptsUnencrypted, $i.UnencryptedRemote, $i.UnencryptedLocal))
						$lines.Add("      $($i.Hint)")
					}
					$lines.Add('')
					$lines.Add('# VERBINDUNGEN')
					if ($connResults.Count -eq 0) { $lines.Add('  (keine)') }
					foreach ($c in ($connResults | Sort-Object SqlInstance, @{ Expression = { - $_.ConnectionCount } }))
					{
						$lines.Add(("  [{0}] {1}  {2}  Host={3}  App={4}  Client={5}  {6}/{7}  x{8}" -f $c.RiskLevel, $c.SqlInstance, $c.LoginName, $c.HostName, $c.ProgramName, $c.ClientAddress, $c.NetTransport, $c.AuthScheme, $c.ConnectionCount))
					}
					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force

					@($connResults) | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

					$enc = { param ($v) [System.Net.WebUtility]::HtmlEncode([string]$v) }
					$cls = @{ Warning = 'warn'; OK = 'ok' }
					$instRows = foreach ($i in $instResults)
					{
						$ca = if ($cls[$i.RiskLevel]) { " class='$($cls[$i.RiskLevel])'" } else { '' }
						"<tr><td$ca>$($i.RiskLevel)</td><td>$(& $enc $i.SqlInstance)</td><td>$($i.ForceEncryption)</td><td>$($i.ForceStrictEncryption)</td>" +
						"<td>$($i.AcceptsUnencrypted)</td><td>$($i.UnencryptedRemote)</td><td>$($i.UnencryptedLocal)</td><td>$(& $enc $i.Hint)</td></tr>"
					}
					$connRows = foreach ($c in ($connResults | Sort-Object SqlInstance, @{ Expression = { - $_.ConnectionCount } }))
					{
						$ca = if ($cls[$c.RiskLevel]) { " class='$($cls[$c.RiskLevel])'" } else { '' }
						"<tr><td$ca>$($c.RiskLevel)</td><td>$(& $enc $c.SqlInstance)</td><td>$(& $enc $c.LoginName)</td><td>$(& $enc $c.HostName)</td>" +
						"<td>$(& $enc $c.ProgramName)</td><td>$(& $enc $c.ClientAddress)</td><td>$(& $enc $c.NetTransport)</td><td>$(& $enc $c.AuthScheme)</td>" +
						"<td>$($c.ConnectionCount)</td><td>$($c.OldestLogin)</td></tr>"
					}
					$bodyHtml = "<p>Instanzen, die unverschluesselt annehmen: $cntAccept von $($instResults.Count) | Instanzen mit unverschluesselten Remote-Verbindungen: $cntWarn | Remote-Verbindungen jetzt: $cntRemote</p>" +
					"<p>Momentaufnahme: nur aktuell offene Verbindungen. Zu verschiedenen Zeiten wiederholen.</p>" +
					"<h2>Instanzen</h2><table><tr><th>Risiko</th><th>Instanz</th><th>ForceEncryption</th><th>Strict</th><th>Nimmt an</th><th>Remote</th><th>Lokal</th><th>Hinweis</th></tr>" +
					($instRows -join '') + "</table>" +
					"<h2>Verbindungen</h2><table><tr><th>Risiko</th><th>Instanz</th><th>Login</th><th>Host</th><th>Programm</th><th>Client</th><th>Transport</th><th>Auth</th><th>Anzahl</th><th>Aelteste Anmeldung</th></tr>" +
					($connRows -join '') + "</table>"
					$html = ConvertTo-sqmHtmlReport -Title 'Unverschluesselte Verbindungen' -Subtitle "Instanz(en): $instanceList | Erstellt: $timestamp" -BodyHtml $bodyHtml
					$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

					Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen
					Invoke-sqmLogging -Message "Bericht erstellt: $htmlFile" -FunctionName $functionName -Level 'INFO'
				}
				catch
				{
					Invoke-sqmLogging -Message "Bericht konnte nicht geschrieben werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
				}
			}
		}

		Invoke-sqmLogging -Message "$functionName abgeschlossen. Instanzen: $($instResults.Count), Verbindungsgruppen: $($connResults.Count)." -FunctionName $functionName -Level 'INFO'
		if ($InstanceSummary) { return $instResults }
		return $connResults
	}
}
