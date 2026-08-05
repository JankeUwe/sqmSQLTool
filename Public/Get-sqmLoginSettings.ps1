<#
.SYNOPSIS
    Zeigt alle Logins mit Default-Datenbank und Spracheinstellung.

.DESCRIPTION
    Liest sys.server_principals (LEFT JOIN sys.sql_logins fuer SQL-Logins) und gibt pro
    Login aus:
    - Name, Typ (SQL / Windows-User / Windows-Gruppe)
    - Default-Datenbank
    - Default-Sprache
    - Aktiviert / deaktiviert
    - Erstellungs- und Aenderungsdatum
    - Kennwort-Richtlinie erzwungen (CHECK_POLICY), Kennwortablauf erzwungen
      (CHECK_EXPIRATION), Kennwort aktuell abgelaufen, "Benutzer muss Kennwort bei
      naechster Anmeldung aendern" und verbleibende Tage bis zum Ablauf - nur fuer
      SQL-Logins gefuellt (via sys.sql_logins / LOGINPROPERTY), bei Windows-Logins/
      -Gruppen $null, da deren Kennwortrichtlinie ueber AD und nicht ueber SQL Server
      verwaltet wird.
    - Mitgliedschaft in der festen Serverrolle sysadmin, in zwei Auspraegungen:
      IsSysAdmin = privilegiert ueber IRGENDEINEN Pfad (effektiv per IS_SRVROLEMEMBER, also
      inklusive Vererbung ueber Windows-/AD-Gruppen, ODER direkt laut Katalogsicht) - das ist
      die sicherheitsrelevante Sicht, denn wer nur ueber eine AD-Gruppe sysadmin ist, hat
      dieselben Rechte, taucht aber in sys.server_role_members nicht auf.
      IsSysAdminDirect = ausschliesslich direkte Mitgliedschaft laut sys.server_role_members.
      Weichen beide voneinander ab (IsSysAdmin=True, IsSysAdminDirect=False), sind die Rechte
      ueber eine Gruppe geerbt und lassen sich nicht per ALTER SERVER ROLE ... DROP MEMBER am
      Login selbst entziehen, sondern nur ueber die Gruppenmitgliedschaft.
    - Ein daraus abgeleitetes RiskLevel ('Critical' / 'Warning' / 'OK' / 'N/A') plus
      RiskIcon (roter/gelber/gruener/grauer Punkt) fuer eine kompakte Sicherheitsampel:
      Kennwort-Richtlinie oder -Ablauf deaktiviert bei einem sysadmin-Login ist Critical,
      beim Nicht-sysadmin-Login nur Warning; ohne jede Abweichung OK. Gilt nur fuer
      SQL-Logins (bei Windows-Logins/-Gruppen greift die Kennwortrichtlinie von AD, nicht
      von SQL Server - dort N/A statt eines falschen Befundes).

    Ausgabe direkt als Objekte. Optional als CSV nach OutputPath.

.PARAMETER SqlInstance
    SQL Server-Instanz(en). Pipeline-faehig. Standard: aktueller Computername.

.PARAMETER SqlCredential
    Optionales PSCredential.

.PARAMETER LoginType
    Filter: 'All' (Standard), 'SQL', 'Windows'

.PARAMETER ExcludeSystemLogins
    NT SERVICE\*, NT AUTHORITY\*, ##MS_*## automatisch ausblenden.

.PARAMETER DefaultDatabase
    Filter: nur Logins mit dieser Default-Datenbank anzeigen.

.PARAMETER DefaultLanguage
    Filter: nur Logins mit dieser Sprache anzeigen.

.PARAMETER OutputPath
    Wenn angegeben, wird eine CSV-Datei geschrieben.
    Standard: kein Export.

.PARAMETER ContinueOnError
    Bei Fehler auf einer Instanz fortfahren.

.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen.

.EXAMPLE
    Get-sqmLoginSettings

.EXAMPLE
    Get-sqmLoginSettings -SqlInstance "SQL01" -ExcludeSystemLogins

.EXAMPLE
    Get-sqmLoginSettings -SqlInstance "SQL01" -DefaultDatabase "master" -DefaultLanguage "us_english"

.EXAMPLE
    Get-sqmLoginSettings -SqlInstance "SQL01","SQL02" -OutputPath "C:\Reports"

.EXAMPLE
    Get-sqmLoginSettings -SqlInstance "SQL01" | Where-Object RiskLevel -in 'Critical', 'Warning'

    Nur SQL-Logins mit deaktivierter Kennwort-Richtlinie/-Ablauf anzeigen (Critical = zusaetzlich
    sysadmin, Warning = nicht-privilegiert).

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging
    LOGINPROPERTY() liefert die Kennwort-Felder nur fuer den aufrufenden Login selbst oder
    mit sysadmin/securityadmin-Rechten fuer beliebige Logins - dbatools verbindet ueblicherweise
    als sysadmin, daher im Regelfall ohne Einschraenkung nutzbar.
#>
function Get-sqmLoginSettings
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[ValidateSet('All', 'SQL', 'Windows')]
		[string]$LoginType = 'All',

		[Parameter(Mandatory = $false)]
		[switch]$ExcludeSystemLogins,

		[Parameter(Mandatory = $false)]
		[string]$DefaultDatabase,

		[Parameter(Mandatory = $false)]
		[string]$DefaultLanguage,

		[Parameter(Mandatory = $false)]
		[string]$OutputPath,

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
		$allResults   = [System.Collections.Generic.List[PSCustomObject]]::new()

		$typeFilter = switch ($LoginType)
		{
			'SQL'     { "'S'" }
			'Windows' { "'U','G'" }
			default   { "'S','U','G'" }
		}

		$query = @"
SELECT
    sp.name                  AS LoginName,
    sp.type_desc              AS LoginType,
    sp.default_database_name  AS DefaultDatabase,
    sp.default_language_name  AS DefaultLanguage,
    sp.is_disabled             AS IsDisabled,
    sp.create_date             AS CreateDate,
    sp.modify_date             AS ModifyDate,
    sl.is_policy_checked       AS PasswordPolicyEnforced,
    sl.is_expiration_checked   AS PasswordExpirationEnforced,
    CAST(LOGINPROPERTY(sp.name, 'IsExpired') AS bit)     AS PasswordExpired,
    CAST(LOGINPROPERTY(sp.name, 'IsMustChange') AS bit)  AS MustChangePassword,
    LOGINPROPERTY(sp.name, 'DaysUntilExpiration')        AS DaysUntilExpiration,
    -- IsSysAdmin = privilegiert ueber IRGENDEINEN Pfad. Bewusst die Kombination aus beidem:
    --   IS_SRVROLEMEMBER() = EFFEKTIVE Mitgliedschaft inkl. Vererbung ueber Windows-/AD-Gruppen
    --     (ein Login, das nur ueber eine AD-Gruppe sysadmin ist, taucht in server_role_members
    --      gar nicht auf - allein per Katalogsicht wuerde der Report ihn als harmlos ausweisen),
    --   sys.server_role_members = DIREKTE Mitgliedschaft
    --     (IS_SRVROLEMEMBER() kann seinerseits 0 liefern, obwohl direkte Mitgliedschaft besteht -
    --      auf DEV01 mit 'NT Service\MSSQLSERVER' reproduziert).
    -- Nur eine der beiden Quellen wuerde also je nach Richtung untertreiben. ISNULL(), weil
    -- IS_SRVROLEMEMBER() NULL liefert, wenn der Login nicht aufloesbar ist (z.B. verwaiste
    -- AD-Konten) - das darf nicht als "privilegiert" durchgehen, die Direktpruefung bleibt.
    CASE WHEN ISNULL(IS_SRVROLEMEMBER('sysadmin', sp.name), 0) = 1
              OR srm.member_principal_id IS NOT NULL
         THEN 1 ELSE 0 END AS IsSysAdmin,
    CASE WHEN srm.member_principal_id IS NOT NULL THEN 1 ELSE 0 END AS IsSysAdminDirect
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins sl ON sl.principal_id = sp.principal_id
LEFT JOIN sys.server_role_members srm
    ON srm.member_principal_id = sp.principal_id
   AND srm.role_principal_id = (SELECT principal_id FROM sys.server_principals WHERE name = 'sysadmin' AND type = 'R')
WHERE sp.type IN ($typeFilter)
  AND sp.name NOT LIKE '##%##'
ORDER BY sp.type_desc, sp.name
"@

		$sysPatterns = @('NT SERVICE\*', 'NT AUTHORITY\*', '##MS_*##')

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

				$rows = Invoke-DbaQuery @connParams -Query $query -EnableException:$EnableException

				foreach ($row in $rows)
				{
					# System-Logins ausblenden
					if ($ExcludeSystemLogins)
					{
						$skip = $false
						foreach ($p in $sysPatterns)
						{
							if ($row.LoginName -like $p) { $skip = $true; break }
						}
						if ($skip) { continue }
					}

					# Filter DefaultDatabase
					if ($DefaultDatabase -and $row.DefaultDatabase -ne $DefaultDatabase) { continue }

					# Filter DefaultLanguage
					if ($DefaultLanguage -and $row.DefaultLanguage -ne $DefaultLanguage) { continue }

					# sys.sql_logins-Spalten und LOGINPROPERTY() liefern fuer Windows-Logins/-Gruppen
					# (kein Eintrag in sys.sql_logins) SQL NULL zurueck - Invoke-DbaQuery gibt das ohne
					# -As PSObject als [DBNull] durch, nicht als PowerShell-$null. [bool]([DBNull]::Value)
					# wirft eine Ausnahme, daher hier explizit auf [DBNull] pruefen statt zu casten.
					$policyEnforced     = if ($row.PasswordPolicyEnforced -is [DBNull]) { $null } else { [bool]$row.PasswordPolicyEnforced }
					$expirationEnforced = if ($row.PasswordExpirationEnforced -is [DBNull]) { $null } else { [bool]$row.PasswordExpirationEnforced }
					$isSysAdmin         = [bool]$row.IsSysAdmin
					$isSysAdminDirect   = [bool]$row.IsSysAdminDirect

					# Sicherheitsampel: Kennwort-Richtlinie/-Ablauf gilt nur fuer SQL-Logins (bei
					# Windows-Logins/-Gruppen sind die Felder oben bewusst $null - AD, nicht SQL Server,
					# verwaltet deren Kennwortrichtlinie) - dort N/A statt eines falschen Befundes.
					# Deaktivierte Richtlinie/Ablauf bei einem sysadmin-Login ist Critical (privilegiertes
					# Konto ohne Kennwortschutz), beim Nicht-sysadmin nur Warning; ohne Abweichung OK.
					if ($row.LoginType -ne 'SQL_LOGIN')
					{
						$riskLevel = 'N/A'; $riskIcon = '⚪'
					}
					elseif ($policyEnforced -eq $false -or $expirationEnforced -eq $false)
					{
						if ($isSysAdmin) { $riskLevel = 'Critical'; $riskIcon = '🔴' }
						else { $riskLevel = 'Warning'; $riskIcon = '🟡' }
					}
					else
					{
						$riskLevel = 'OK'; $riskIcon = '🟢'
					}

					$allResults.Add([PSCustomObject]@{
						SqlInstance                = $instance
						LoginName                  = $row.LoginName
						LoginType                  = $row.LoginType
						IsSysAdmin                 = $isSysAdmin
						IsSysAdminDirect           = $isSysAdminDirect
						RiskLevel                  = $riskLevel
						RiskIcon                   = $riskIcon
						DefaultDatabase            = $row.DefaultDatabase
						DefaultLanguage            = $row.DefaultLanguage
						IsDisabled                 = [bool]$row.IsDisabled
						CreateDate                 = $row.CreateDate
						ModifyDate                 = $row.ModifyDate
						PasswordPolicyEnforced     = $policyEnforced
						PasswordExpirationEnforced = $expirationEnforced
						PasswordExpired            = if ($row.PasswordExpired -is [DBNull]) { $null } else { [bool]$row.PasswordExpired }
						MustChangePassword         = if ($row.MustChangePassword -is [DBNull]) { $null } else { [bool]$row.MustChangePassword }
						DaysUntilExpiration        = if ($row.DaysUntilExpiration -is [DBNull]) { $null } else { [int]$row.DaysUntilExpiration }
					})
				}

				Invoke-sqmLogging -Message "[$instance] $($allResults.Count) Login(s) gelesen." -FunctionName $functionName -Level 'INFO'
			}
			catch
			{
				$errMsg = "[$instance] Fehler: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
				if ($EnableException) { throw }
				if (-not $ContinueOnError) { throw $_ }
			}
		}
	}

	end
	{
		# Optionaler CSV-Export
		if ($OutputPath -and $allResults.Count -gt 0)
		{
			try
			{
				if (-not (Test-Path $OutputPath))
				{
					New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
				}
				$csvFile = Join-Path $OutputPath "LoginSettings_$(Get-Date -Format 'yyyy-MM-dd').csv"
				$allResults | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force
				Invoke-sqmLogging -Message "CSV geschrieben: $csvFile" -FunctionName $functionName -Level 'INFO'

				$htmlFile = Join-Path $OutputPath "LoginSettings_$(Get-Date -Format 'yyyy-MM-dd').html"
				$bodyHtml = ($allResults | ConvertTo-Html -Fragment -As Table | Out-String)
				$html = ConvertTo-sqmHtmlReport -Title "Login Settings" -Subtitle "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -BodyHtml $bodyHtml
				$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
				Invoke-sqmOpenReport -HtmlFile $htmlFile -NoOpen:$NoOpen
			}
			catch
			{
				Invoke-sqmLogging -Message "CSV-Export fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
			}
		}

		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Login(s) gesamt." -FunctionName $functionName -Level 'INFO'
		return $allResults
	}
}
