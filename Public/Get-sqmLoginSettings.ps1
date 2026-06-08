<#
.SYNOPSIS
    Zeigt alle Logins mit Default-Datenbank und Spracheinstellung.

.DESCRIPTION
    Liest sys.server_principals und sys.sql_logins und gibt pro Login aus:
    - Name, Typ (SQL / Windows-User / Windows-Gruppe)
    - Default-Datenbank
    - Default-Sprache
    - Aktiviert / deaktiviert
    - Password Policy (nur SQL-Logins)

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

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging
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
		[switch]$EnableException
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
    sp.name                    AS LoginName,
    sp.type_desc               AS LoginType,
    sp.default_database_name   AS DefaultDatabase,
    sp.default_language_name   AS DefaultLanguage,
    sp.is_disabled             AS IsDisabled,
    sp.create_date             AS CreateDate,
    sp.modify_date             AS ModifyDate,
    ISNULL(sl.is_policy_checked, 0)    AS IsPolicyChecked,
    ISNULL(sl.is_expiration_checked, 0) AS IsExpirationChecked,
    ISNULL(sl.must_change_password, 0)  AS MustChangePassword
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins sl ON sl.principal_id = sp.principal_id
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

					$allResults.Add([PSCustomObject]@{
						SqlInstance          = $instance
						LoginName            = $row.LoginName
						LoginType            = $row.LoginType
						DefaultDatabase      = $row.DefaultDatabase
						DefaultLanguage      = $row.DefaultLanguage
						IsDisabled           = [bool]$row.IsDisabled
						IsPolicyChecked      = [bool]$row.IsPolicyChecked
						IsExpirationChecked  = [bool]$row.IsExpirationChecked
						MustChangePassword   = [bool]$row.MustChangePassword
						CreateDate           = $row.CreateDate
						ModifyDate           = $row.ModifyDate
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
