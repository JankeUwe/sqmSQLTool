<#
.SYNOPSIS
    Finds tables, views, procedures, and functions in the master database that were not
    Microsoft-shipped and are not on the configured whitelist of expected maintenance tooling.

.DESCRIPTION
    Users occasionally create objects directly in master by accident (wrong database selected
    in SSMS, a script run without a USE statement, ad-hoc troubleshooting left behind). Unlike
    a user database, master has no natural owner for "this shouldn't be here" - anything not
    shipped by Microsoft and not part of the standard maintenance tooling is a candidate for
    cleanup.

    Reads sys.objects in master for tables, views, procedures, and functions
    (U/V/P/PC/FN/IF/TF/FS/FT), excluding genuine Microsoft-shipped objects (is_ms_shipped = 1)
    and anything matched by the MasterDbObjectWhitelist module configuration (wildcards
    allowed) - see Get-sqmConfig -Key 'MasterDbObjectWhitelist' / Set-sqmConfig
    -MasterDbObjectWhitelist. The default whitelist covers the standard maintenance-script
    family: sp_Blitz*, sp_WhoIsActive, Ola Hallengren's CommandExecute/CommandLog/
    DatabaseBackup/DatabaseIntegrityCheck/IndexOptimize, and sp_BackRestRemain.

    Output as PowerShell objects (one row per found object, plus one OK row per instance with
    nothing found), plus TXT/CSV/HTML report files. This function only reports - use
    Remove-sqmMasterDbCustomObjects to drop what it finds.

.PARAMETER SqlInstance
    SQL Server instance(s). Pipeline-capable. Default: current computer name.

.PARAMETER SqlCredential
    Optional PSCredential.

.PARAMETER ExcludeObject
    Additional object names to exclude for this call only (wildcards allowed), on top of the
    configured MasterDbObjectWhitelist. Use for a one-off tool you know is legitimate without
    changing the persisted configuration.

.PARAMETER OutputPath
    Output directory for the report (HTML/TXT/CSV). Default: <module OutputPath>\MasterDbCustomObjects.

.PARAMETER ContinueOnError
    Continue with the next instance on error.

.PARAMETER EnableException
    Throw exceptions immediately instead of just logging them.

.PARAMETER NoOpen
    Do not automatically open the report after creating it.

.PARAMETER Confirm
    Ask before writing the report files.

.PARAMETER WhatIf
    Show which report files would be created without writing them.

.EXAMPLE
    Get-sqmMasterDbCustomObjects

.EXAMPLE
    Get-sqmMasterDbCustomObjects -SqlInstance 'SQL01','SQL02' -ExcludeObject 'usp_MyAdminTool'

.EXAMPLE
    Get-sqmMasterDbCustomObjects -SqlInstance 'SQL01' | Where-Object Status -eq 'Custom'

.EXAMPLE
    Get-sqmMasterDbCustomObjects -SqlInstance 'SQL01' | Where-Object Status -eq 'Custom' | Remove-sqmMasterDbCustomObjects -WhatIf

    Feeds the findings straight into the removal function (dry run first).

.NOTES
    Requires: dbatools, Invoke-sqmLogging
    See also: Remove-sqmMasterDbCustomObjects, Set-sqmConfig -MasterDbObjectWhitelist
#>
function Get-sqmMasterDbCustomObjects
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true, Position = 0)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeObject = @(),

		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'MasterDbCustomObjects'),

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

		if (-not $script:dbatoolsAvailable)
		{
			$msg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}

		$whitelist = @(Get-sqmConfig -Key 'MasterDbObjectWhitelist')
		$excludePatterns = @($whitelist) + @($ExcludeObject)

		$objectQuery = @"
SELECT
    s.name       AS SchemaName,
    o.name       AS ObjectName,
    o.type       AS ObjectTypeCode,
    o.type_desc  AS ObjectTypeDesc,
    o.create_date AS CreateDate,
    o.modify_date AS ModifyDate
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.type IN ('U','V','P','PC','FN','IF','TF','FS','FT')
  AND o.is_ms_shipped = 0
ORDER BY o.type_desc, s.name, o.name
"@

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

				$rows = Invoke-DbaQuery @connParams -Database 'master' -Query $objectQuery -ErrorAction Stop

				$found = @($rows | Where-Object {
					$n = $_.ObjectName
					$excluded = $false
					foreach ($pattern in $excludePatterns) { if ($n -like $pattern) { $excluded = $true } }
					-not $excluded
				})

				if ($found.Count -eq 0)
				{
					$allResults.Add([PSCustomObject]@{
						SqlInstance    = $instance
						Status         = 'OK'
						RiskIcon       = '🟢'
						SchemaName     = $null
						ObjectName     = $null
						ObjectType     = $null
						ObjectTypeCode = $null
						CreateDate     = $null
						ModifyDate     = $null
						Message        = 'Keine unerwarteten Objekte in master.'
					})
				}
				else
				{
					foreach ($o in $found)
					{
						$allResults.Add([PSCustomObject]@{
							SqlInstance    = $instance
							Status         = 'Custom'
							RiskIcon       = '🟡'
							SchemaName     = $o.SchemaName
							ObjectName     = $o.ObjectName
							ObjectType     = $o.ObjectTypeDesc
							ObjectTypeCode = $o.ObjectTypeCode.Trim()
							CreateDate     = $o.CreateDate
							ModifyDate     = $o.ModifyDate
							Message        = "Nicht auf der Whitelist: $($o.SchemaName).$($o.ObjectName) ($($o.ObjectTypeDesc))"
						})
					}
				}

				Invoke-sqmLogging -Message "[$instance] $($found.Count) unerwartete(s) Objekt(e) in master gefunden." -FunctionName $functionName -Level 'INFO'
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
		if ($allResults.Count -gt 0)
		{
			$cntCustom = @($allResults | Where-Object Status -eq 'Custom').Count
			$cntOk     = @($allResults | Where-Object Status -eq 'OK').Count
			$instanceList = ($SqlInstance -join ', ')

			if ($PSCmdlet.ShouldProcess($instanceList, "Erstelle master-Objekt-Bericht in $OutputPath"))
			{
				try
				{
					if (-not (Test-Path $OutputPath))
					{
						New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
						Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level 'INFO'
					}

					$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
					$datestamp = Get-Date -Format 'yyyy-MM-dd'
					$safeInst  = ($SqlInstance -join '_') -replace '[\\/:*?"<>|]', '_'
					if ($safeInst.Length -gt 60) { $safeInst = $safeInst.Substring(0, 60) }
					$txtFile  = Join-Path $OutputPath "MasterDbCustomObjects_${safeInst}_${datestamp}.txt"
					$csvFile  = Join-Path $OutputPath "MasterDbCustomObjects_${safeInst}_${datestamp}.csv"
					$htmlFile = Join-Path $OutputPath "MasterDbCustomObjects_${safeInst}_${datestamp}.html"

					$sorted = $allResults | Sort-Object @{ Expression = { if ($_.Status -eq 'Custom') { 0 } else { 1 } } }, SqlInstance, SchemaName, ObjectName

					# -- TXT --
					$lines = [System.Collections.Generic.List[string]]::new()
					$lines.Add("# ================================================================")
					$lines.Add("# sqmSQLTool - master DB Custom-Objekte Bericht")
					$lines.Add("# $(Get-sqmReportReference)")
					$lines.Add("# Instanz(en): $instanceList")
					$lines.Add("# Erstellt   : $timestamp")
					$lines.Add("# Whitelist  : $($whitelist -join ', ')")
					$lines.Add("# Gefunden   : $cntCustom unerwartete(s) Objekt(e) | OK: $cntOk Instanz(en) sauber")
					$lines.Add("# ================================================================")
					$lines.Add("")

					foreach ($e in ($allResults | Where-Object Status -eq 'Custom' | Sort-Object SqlInstance, SchemaName, ObjectName))
					{
						$lines.Add(("  {0,-20} {1,-10} {2,-30} {3,-25} {4}" -f $e.SqlInstance, $e.ObjectTypeCode, "$($e.SchemaName).$($e.ObjectName)", $e.CreateDate, $e.ObjectType))
					}
					if ($cntCustom -eq 0) { $lines.Add("  (keine unerwarteten Objekte gefunden)") }

					$lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
					$allResults | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

					# -- HTML: gelb (Custom) / gruen (OK) --
					$rowsHtml = foreach ($e in $sorted)
					{
						$cssClass = if ($e.Status -eq 'OK') { 'ok' } else { 'warn' }
						"<tr><td class='$cssClass'>$($e.RiskIcon) $($e.Status)</td>" +
							"<td>$([System.Net.WebUtility]::HtmlEncode($e.SqlInstance))</td>" +
							"<td>$([System.Net.WebUtility]::HtmlEncode($e.SchemaName))</td>" +
							"<td>$([System.Net.WebUtility]::HtmlEncode($e.ObjectName))</td>" +
							"<td>$([System.Net.WebUtility]::HtmlEncode($e.ObjectType))</td>" +
							"<td>$($e.CreateDate)</td>" +
							"<td>$([System.Net.WebUtility]::HtmlEncode($e.Message))</td></tr>"
					}
					$bodyHtml = "<p>Gefunden: $cntCustom unerwartete(s) Objekt(e) | Saubere Instanz(en): $cntOk</p>" +
						"<p>Whitelist: $([System.Net.WebUtility]::HtmlEncode(($whitelist -join ', ')))</p>" +
						"<table><tr><th>Status</th><th>Instanz</th><th>Schema</th><th>Objekt</th><th>Typ</th><th>Erstellt</th><th>Meldung</th></tr>" +
						($rowsHtml -join '') + "</table>"
					$html = ConvertTo-sqmHtmlReport -Title "master DB Custom-Objekte" -Subtitle "Instanz(en): $instanceList | Erstellt: $timestamp" -BodyHtml $bodyHtml
					$html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

					Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen
					Invoke-sqmLogging -Message "Bericht erstellt: $htmlFile" -FunctionName $functionName -Level 'INFO'
				}
				catch
				{
					Invoke-sqmLogging -Message "Bericht konnte nicht geschrieben werden: $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
				}
			}

			if ($cntCustom -gt 0)
			{
				Invoke-sqmLogging -Message "$cntCustom unerwartete(s) Objekt(e) in master gefunden." -FunctionName $functionName -Level 'WARNING'
			}
		}

		Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Zeile(n) gesamt." -FunctionName $functionName -Level 'INFO'
		return $allResults
	}
}
