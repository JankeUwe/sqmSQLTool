<#
.SYNOPSIS
    Migrates Reporting Services content (report projects: folders, shared data sources, shared
    datasets, reports, resources) from one report server to another, including the data source
    bindings that a plain RDL copy loses.

.DESCRIPTION
    Copying the .rdl files is not a migration. A report on the server is bound to its shared data
    sources and shared datasets by the catalog, not by the text in the RDL: Visual Studio deploys
    with TargetDataSourceFolder, and anyone can re-point a report in the web portal afterwards.
    Re-uploading only the RDL lands reports on the new server that either point nowhere ("The
    report server cannot process the report. The data source connection information has been
    deleted") or still point at a path that only existed on the old server. Stored data source
    passwords cannot be read through any API, so they are lost silently as well.

    This function works through the SSRS REST API v2.0 (SSRS 2017 and later, Power BI Report
    Server) and therefore runs under Windows PowerShell 5.1 and PowerShell 7 alike:

      1. Connects to both servers and reads the version.
      2. Inventories every -SourceFolder recursively: folders, shared data sources (with their
         definition), shared datasets, reports (with their data source bindings and shared
         dataset references), linked reports, resources, Power BI reports and Excel workbooks.
      3. Resolves dependencies OUTSIDE the migrated folders - typically "/Data Sources" and
         "/Datasets" - and takes them along at their original path. -SkipDependencies turns
         that off.
      4. Plans every item against the destination: Create, Overwrite or Skip (exists). Data
         sources that store a password are flagged unless -DataSourceCredential supplies it.
      5. Exports the source content to disk (Source\... below the report folder) and backs up
         every destination item before it is overwritten (DestinationBackup\...).
      6. Writes in dependency order: folders, data sources, datasets, resources, reports, linked
         reports, Power BI reports / workbooks. Absolute <DataSourceReference> and
         <SharedDataSetReference> paths in RDL/RSD content are rewritten when -DestinationFolder
         moves the content to a different path.
      7. Re-applies the data source bindings of every report and dataset from the SOURCE
         catalog (not from the RDL text), with paths mapped to the destination, plus connection
         string replacements (-ConnectionStringMap) and stored passwords.
      8. Optionally copies item security (-IncludeSecurity) for every item that does not inherit
         its parent's policy.
      9. Verifies the bindings by reading them back from the destination.
     10. Lists subscriptions on the migrated reports. They are NOT copied: they carry the owner,
         schedule and delivery settings of the old server and must be recreated deliberately.

    Nothing on the source is changed. -AssessOnly stops after step 4 and changes nothing on the
    destination either.

.PARAMETER SourceReportServer
    Source report server. Accepted forms: "SRV", "https://srv:8443", "http://srv/ReportServer",
    "http://srv/Reports", "http://srv/ReportServer_INST" (named instance) or the full REST base
    ".../api/v2.0" for custom virtual directories.

.PARAMETER SourceCredential
    Windows credential for the source (NTLM/Kerberos). Default: the current user.

.PARAMETER DestinationReportServer
    Destination report server, same forms as -SourceReportServer. May be the same server as the
    source when -DestinationFolder differs from -SourceFolder (copying a project within a server).

.PARAMETER DestinationCredential
    Windows credential for the destination. Default: the current user.

.PARAMETER SourceFolder
    Folder(s) to migrate, recursively. Default "/" (the entire catalog). Paths start with "/".

.PARAMETER DestinationFolder
    Destination path that replaces -SourceFolder (e.g. "/Finance" -> "/Archive/Finance"). Only
    allowed with a single -SourceFolder. Default: same path as on the source.

.PARAMETER ItemType
    Item types to migrate. Default: all supported types. Folders are always created as needed.

.PARAMETER ConnectionStringMap
    Text replacements for connection strings of shared and embedded data sources, as
    "OLD=>NEW" entries, case-insensitive, applied in order. Example: 'SQLOLD01=>SQLNEW01'.

.PARAMETER DataSourceCredential
    Credentials for data sources that store a user name and password on the server ("Credentials
    stored securely in the report server"). The password cannot be read from the source; it is
    matched to the data sources by the stored user name. One PSCredential per stored user.

.PARAMETER Overwrite
    Overwrite existing reports, datasets, resources, linked reports and Power BI items on the
    destination (the item keeps its ID, so destination subscriptions and history stay attached).
    Without it, existing items are skipped.

.PARAMETER OverwriteDataSources
    Also overwrite existing shared data sources on the destination. Separate from -Overwrite
    because a data source that already exists on the destination usually carries the correct
    connection and password for that environment.

.PARAMETER IncludeSecurity
    Copy item-level security (role assignments) for every folder and item that breaks
    inheritance. The users/groups and the role names must exist on the destination.

.PARAMETER SkipDependencies
    Do not take along shared data sources/datasets outside -SourceFolder that the migrated
    reports reference.

.PARAMETER SkipCertificateCheck
    Accept untrusted HTTPS certificates (self-signed, internal CA not trusted on this machine).

.PARAMETER AssessOnly
    Only inventory and plan. Changes nothing on the destination.

.PARAMETER OutputPath
    Directory for the HTML report and the content export. Default: <OutputPath config>\SsrsMigration.

.PARAMETER NoOpen
    Do not open the report after the run.

.PARAMETER NoReport
    Do not write the HTML report (the content export is still written).

.PARAMETER EnableException
    Throw exceptions immediately instead of returning a result object with Status 'Failed'.

.EXAMPLE
    Invoke-sqmSsrsMigration -SourceReportServer SSRSOLD -DestinationReportServer SSRSNEW -SourceFolder '/Finance' -AssessOnly

    The planning run: what is in the project, what it references outside the folder, what exists
    on the destination already, and which data sources need a password.

.EXAMPLE
    $cred = Get-Credential rpt_reader
    Invoke-sqmSsrsMigration -SourceReportServer SSRSOLD -DestinationReportServer SSRSNEW `
        -SourceFolder '/Finance' -ConnectionStringMap 'SQLOLD01=>SQLNEW01' -DataSourceCredential $cred `
        -IncludeSecurity -Confirm:$false

    The migration, with the data sources re-pointed to the new database server.

.EXAMPLE
    Invoke-sqmSsrsMigration -SourceReportServer SSRS01 -DestinationReportServer SSRS01 `
        -SourceFolder '/Finance' -DestinationFolder '/Test/Finance' -Overwrite

    Copies a project within one server to a different folder; references inside the project
    follow the copy.

.NOTES
    Requires SSRS 2017 or later (REST API v2.0) or Power BI Report Server on both sides, and the
    Content Manager role (or System Administrator for -IncludeSecurity) on the affected folders.

    Not migrated: subscriptions (listed), cache/history/snapshot settings, shared schedules,
    report parameters set on the server, KPIs and mobile reports. Paginated reports keep their
    report-server-side parameter defaults only when they are part of the RDL.

.LINK
    Install-sqmSsrsReportServer
    Set-sqmSsrsConfiguration
#>
function Invoke-sqmSsrsMigration
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SourceReportServer,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SourceCredential,

		[Parameter(Mandatory = $true)]
		[string]$DestinationReportServer,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$DestinationCredential,

		[Parameter(Mandatory = $false)]
		[string[]]$SourceFolder = @('/'),

		[Parameter(Mandatory = $false)]
		[string]$DestinationFolder,

		[Parameter(Mandatory = $false)]
		[ValidateSet('DataSource', 'DataSet', 'Report', 'LinkedReport', 'Resource', 'PowerBIReport', 'ExcelWorkbook')]
		[string[]]$ItemType = @('DataSource', 'DataSet', 'Report', 'LinkedReport', 'Resource', 'PowerBIReport', 'ExcelWorkbook'),

		[Parameter(Mandatory = $false)]
		[string[]]$ConnectionStringMap,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential[]]$DataSourceCredential,

		[Parameter(Mandatory = $false)]
		[switch]$Overwrite,

		[Parameter(Mandatory = $false)]
		[switch]$OverwriteDataSources,

		[Parameter(Mandatory = $false)]
		[switch]$IncludeSecurity,

		[Parameter(Mandatory = $false)]
		[switch]$SkipDependencies,

		[Parameter(Mandatory = $false)]
		[switch]$SkipCertificateCheck,

		[Parameter(Mandatory = $false)]
		[switch]$AssessOnly,

		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'SsrsMigration'),

		[Parameter(Mandatory = $false)]
		[switch]$NoOpen,

		[Parameter(Mandatory = $false)]
		[switch]$NoReport,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

		$steps = [System.Collections.Generic.List[PSCustomObject]]::new()
		$addStep = {
			param ([string]$Step, [string]$Status, [string]$Detail)
			$steps.Add([PSCustomObject]@{
					Step      = $Step
					Status    = $Status
					Detail    = $Detail
					Timestamp = Get-Date
				})
			$level = 'INFO'
			if ($Status -eq 'Failed') { $level = 'ERROR' }
			elseif ($Status -eq 'Blocked' -or $Status -eq 'Warning') { $level = 'WARNING' }
			Invoke-sqmLogging -Message "[$Status] $Step - $Detail" -FunctionName $functionName -Level $level
		}

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
				if ($ptr -ne [System.IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
			}
		}

		# Ordnerpfade normalisieren: fuehrender '/', kein abschliessender. Die Wurzel wird intern
		# als Leerstring gefuehrt, damit "liegt darunter" und "Pfad abbilden" ohne Sonderfall gehen.
		$normalizeFolder = {
			param ([string]$Path)
			$p = ('/' + $Path.Trim().Trim('/')).TrimEnd('/')
			return $p
		}

		$htmlEncode = {
			param ($Value)
			if ($null -eq $Value) { return '' }
			return ([string]$Value -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
		}

		$buildReportBody = {
			param ($Result, $StepList)

			$sb = [System.Text.StringBuilder]::new()
			$null = $sb.AppendLine("<h2>Ergebnis</h2><table><tr><th>Feld</th><th>Wert</th></tr>")
			foreach ($pair in @(
					@('Quelle', $Result.SourceApi),
					@('Ziel', $Result.DestinationApi),
					@('Version Quelle', $Result.SourceVersion),
					@('Version Ziel', $Result.DestinationVersion),
					@('Ordner', ($Result.SourceFolder -join ', ')),
					@('Zielordner', $Result.DestinationFolder),
					@('Aktion', $Result.Action),
					@('Status', $Result.Status),
					@('Begruendung', $Result.Reason),
					@('Elemente', $Result.ItemCount),
					@('Export', $Result.ExportPath)))
			{
				$null = $sb.AppendLine("<tr><td>$(& $htmlEncode $pair[0])</td><td>$(& $htmlEncode $pair[1])</td></tr>")
			}
			$null = $sb.AppendLine("</table>")

			$null = $sb.AppendLine("<h2>Elemente</h2><table><tr><th>Typ</th><th>Quelle</th><th>Ziel</th><th>Plan</th><th>Status</th><th>Detail</th></tr>")
			foreach ($i in $Result.Items)
			{
				$cls = 'ok'
				if ($i.Status -eq 'Failed') { $cls = 'crit' }
				elseif ($i.Status -in @('Warning', 'Skipped', 'NotSupported', 'Planned', 'WhatIf')) { $cls = 'warn' }
				$null = $sb.AppendLine("<tr><td>$(& $htmlEncode $i.Type)</td><td>$(& $htmlEncode $i.SourcePath)</td><td>$(& $htmlEncode $i.DestinationPath)</td><td>$(& $htmlEncode $i.Action)</td><td class='$cls'>$(& $htmlEncode $i.Status)</td><td>$(& $htmlEncode $i.Detail)</td></tr>")
			}
			$null = $sb.AppendLine("</table>")

			$subs = @($Result.Subscriptions)
			if ($subs.Count -gt 0)
			{
				$null = $sb.AppendLine("<h2>Abonnements (nicht migriert, auf dem Ziel neu anlegen)</h2>")
				$null = $sb.AppendLine("<table><tr><th>Bericht</th><th>Beschreibung</th><th>Besitzer</th><th>Zustellung</th><th>Datengesteuert</th><th>Letzter Status</th></tr>")
				foreach ($s in $subs)
				{
					$null = $sb.AppendLine("<tr><td>$(& $htmlEncode $s.Report)</td><td>$(& $htmlEncode $s.Description)</td><td>$(& $htmlEncode $s.Owner)</td><td>$(& $htmlEncode $s.DeliveryExtension)</td><td>$(& $htmlEncode $s.IsDataDriven)</td><td>$(& $htmlEncode $s.LastStatus)</td></tr>")
				}
				$null = $sb.AppendLine("</table>")
			}

			$null = $sb.AppendLine("<h2>Schritte</h2><table><tr><th>Zeit</th><th>Schritt</th><th>Status</th><th>Detail</th></tr>")
			foreach ($s in $StepList)
			{
				$cls = 'ok'
				if ($s.Status -eq 'Failed') { $cls = 'crit' }
				elseif ($s.Status -in @('Blocked', 'Warning', 'WhatIf')) { $cls = 'warn' }
				$null = $sb.AppendLine("<tr><td>$($s.Timestamp.ToString('HH:mm:ss'))</td><td>$(& $htmlEncode $s.Step)</td><td class='$cls'>$(& $htmlEncode $s.Status)</td><td>$(& $htmlEncode $s.Detail)</td></tr>")
			}
			$null = $sb.AppendLine("</table>")
			return $sb.ToString()
		}
	}

	process
	{
		$srcApi = ConvertTo-sqmSsrsApiBase -ReportServer $SourceReportServer
		$dstApi = ConvertTo-sqmSsrsApiBase -ReportServer $DestinationReportServer

		$roots = @($SourceFolder | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { & $normalizeFolder $_ } | Select-Object -Unique)
		if ($roots.Count -eq 0) { $roots = @('') }
		$destRoot = $null
		if ($PSBoundParameters.ContainsKey('DestinationFolder')) { $destRoot = & $normalizeFolder $DestinationFolder }

		$items = [System.Collections.Generic.List[PSCustomObject]]::new()
		$subscriptions = [System.Collections.Generic.List[PSCustomObject]]::new()

		$result = [PSCustomObject]@{
			SourceApi          = $srcApi
			DestinationApi     = $dstApi
			SourceVersion      = $null
			DestinationVersion = $null
			SourceFolder       = @($roots | ForEach-Object { if ($_ -eq '') { '/' } else { $_ } })
			DestinationFolder  = $DestinationFolder
			Action             = 'Migrate'
			Status             = 'Unknown'
			Reason             = ''
			ItemCount          = 0
			Items              = $items
			Subscriptions      = $subscriptions
			ExportPath         = $null
			Steps              = $steps
			ReportFile         = $null
			Timestamp          = Get-Date
		}
		if ($AssessOnly) { $result.Action = 'Assess' }

		$tempDir = $null

		try
		{
			# ==============================================================
			# 0. Parameter, die sich gegenseitig ausschliessen
			# ==============================================================
			if ($null -ne $destRoot -and $roots.Count -gt 1)
			{
				throw "-DestinationFolder ist nur mit genau einem -SourceFolder moeglich (angegeben: $($roots.Count))."
			}
			$sameServer = ($srcApi.TrimEnd('/') -ieq $dstApi.TrimEnd('/'))
			if ($sameServer -and ($null -eq $destRoot -or $roots -contains $destRoot))
			{
				throw "Quelle und Ziel sind derselbe Report Server und derselbe Ordner. Fuer eine Kopie innerhalb des Servers -DestinationFolder angeben."
			}
			if ($sameServer)
			{
				foreach ($r in $roots)
				{
					if ($destRoot.StartsWith("$r/", [System.StringComparison]::OrdinalIgnoreCase) -or $r -eq '')
					{
						throw "-DestinationFolder '$destRoot' liegt innerhalb des Quellordners '$(if ($r) { $r } else { '/' })'. Die Kopie wuerde sich selbst erneut erfassen."
					}
				}
			}

			$csMap = [System.Collections.Generic.List[object]]::new()
			foreach ($entry in @($ConnectionStringMap))
			{
				if ([string]::IsNullOrWhiteSpace($entry)) { continue }
				$idx = $entry.IndexOf('=>')
				if ($idx -lt 1) { throw "-ConnectionStringMap: Eintrag '$entry' hat nicht das Format 'ALT=>NEU'." }
				$csMap.Add(@($entry.Substring(0, $idx).Trim(), $entry.Substring($idx + 2).Trim()))
			}

			$srcCall = {
				param ([string]$Rel, [string]$Method = 'GET', $Body = $null, [string]$OutFile)
				$a = @{ Uri = "$srcApi/$Rel"; Method = $Method; SkipCertificateCheck = $SkipCertificateCheck }
				if ($SourceCredential) { $a['Credential'] = $SourceCredential }
				if ($null -ne $Body) { $a['Body'] = $Body }
				if ($OutFile) { $a['OutFile'] = $OutFile }
				Invoke-sqmSsrsRest @a
			}
			$dstCall = {
				param ([string]$Rel, [string]$Method = 'GET', $Body = $null, [string]$OutFile)
				$a = @{ Uri = "$dstApi/$Rel"; Method = $Method; SkipCertificateCheck = $SkipCertificateCheck }
				if ($DestinationCredential) { $a['Credential'] = $DestinationCredential }
				if ($null -ne $Body) { $a['Body'] = $Body }
				if ($OutFile) { $a['OutFile'] = $OutFile }
				Invoke-sqmSsrsRest @a
			}

			# Liegt ein Quellpfad in einem der migrierten Ordner? Liefert die Wurzel oder $null.
			$rootOf = {
				param ([string]$Path)
				foreach ($r in $roots)
				{
					if ($r -eq '' -or $Path -ieq $r -or $Path.StartsWith("$r/", [System.StringComparison]::OrdinalIgnoreCase)) { return $r }
				}
				return $null
			}
			# Quellpfad -> Zielpfad. Abhaengigkeiten ausserhalb der Ordner behalten ihren Pfad.
			$mapPath = {
				param ([string]$Path)
				if ($null -eq $destRoot) { return $Path }
				$r = & $rootOf $Path
				if ($null -eq $r) { return $Path }
				$mapped = $destRoot + $Path.Substring($r.Length)
				if ($mapped -eq '') { return '/' }
				return $mapped
			}
			$parentOf = {
				param ([string]$Path)
				$i = $Path.LastIndexOf('/')
				if ($i -le 0) { return '/' }
				return $Path.Substring(0, $i)
			}
			$mapConnection = {
				param ([string]$ConnectionString)
				if ([string]::IsNullOrEmpty($ConnectionString)) { return $ConnectionString }
				$cs = $ConnectionString
				foreach ($m in $csMap)
				{
					$cs = [regex]::Replace($cs, [regex]::Escape($m[0]), $m[1].Replace('$', '$$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
				}
				return $cs
			}
			# Gespeichertes Kennwort zu einem Benutzernamen; "DOM\user" passt auch auf "user".
			$findSecret = {
				param ([string]$UserName)
				if ([string]::IsNullOrEmpty($UserName)) { return $null }
				$short = ($UserName -split '\\')[-1]
				foreach ($c in @($DataSourceCredential))
				{
					if (-not $c) { continue }
					$cu = $c.UserName
					if ($cu -ieq $UserName -or ($cu -split '\\')[-1] -ieq $short) { return $c }
				}
				return $null
			}
			$getProp = {
				param ($Object, [string]$Name)
				if ($null -eq $Object) { return $null }
				$p = $Object.PSObject.Properties[$Name]
				if ($p) { return $p.Value }
				return $null
			}
			# Windows-taugliche Dateipfade fuer den Export; SSRS erlaubt Zeichen, die NTFS nicht mag.
			$localPath = {
				param ([string]$BaseDir, [string]$CatalogPath, [string]$Extension)
				$invalid = [System.IO.Path]::GetInvalidFileNameChars()
				$segments = @($CatalogPath.Trim('/') -split '/' | ForEach-Object {
						$s = $_
						foreach ($ch in $invalid) { $s = $s.Replace([string]$ch, '_') }
						$s
					})
				$file = Join-Path $BaseDir ($segments -join '\')
				if ($Extension -and -not $file.EndsWith($Extension, [System.StringComparison]::OrdinalIgnoreCase)) { $file += $Extension }
				$dir = Split-Path $file -Parent
				if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false }
				return $file
			}
			# Typ-spezifische Endpunkte. Anlegen ueber die Typ-Collection, nicht ueber CatalogItems:
			# verknuepfte Berichte gehen nur ueber /LinkedReports.
			$endpointFor = @{
				DataSource    = 'DataSources'
				DataSet       = 'DataSets'
				Report        = 'Reports'
				LinkedReport  = 'LinkedReports'
				Resource      = 'Resources'
				PowerBIReport = 'PowerBIReports'
				ExcelWorkbook = 'ExcelWorkbooks'
			}
			$extensionFor = @{
				Report        = '.rdl'
				DataSet       = '.rsd'
				PowerBIReport = '.pbix'
				ExcelWorkbook = '.xlsx'
				Resource      = ''
			}

			# ==============================================================
			# 1. Verbindung zu beiden Servern
			# ==============================================================
			foreach ($side in @(@('Quelle', $srcCall, 'SourceVersion'), @('Ziel', $dstCall, 'DestinationVersion')))
			{
				try
				{
					$sys = & $side[1] 'System'
					$ver = & $getProp $sys 'ProductVersion'
					$prod = & $getProp $sys 'ProductName'
					$result.($side[2]) = (("$prod $ver").Trim())
					& $addStep "Verbindung $($side[0])" 'Success' $result.($side[2])
				}
				catch
				{
					$hint = ''
					$code = $_.Exception.Data['StatusCode']
					if ($code -eq 401) { $hint = ' Anmeldung abgelehnt: -SourceCredential/-DestinationCredential pruefen (Windows-Konto, kein SQL-Login).' }
					elseif ($code -eq 404) { $hint = ' REST-API nicht gefunden: SSRS 2017 oder neuer noetig; bei eigenem virtuellem Verzeichnis die volle .../api/v2.0-URL angeben.' }
					throw "Report Server ($($side[0])) nicht erreichbar: $($_.Exception.Message)$hint"
				}
			}

			# ==============================================================
			# 2. Inventar der Quelle
			# ==============================================================
			$sourceById = @{}
			$sourceByPath = @{}
			$folders = [System.Collections.Generic.List[object]]::new()

			$registerItem = {
				param ($Item, [bool]$IsDependency)
				$path = [string]$Item.Path
				if ($sourceByPath.ContainsKey($path)) { return $sourceByPath[$path] }
				$entry = [PSCustomObject]@{
					Id              = [string]$Item.Id
					Name            = [string]$Item.Name
					Path            = $path
					Type            = [string]$Item.Type
					Description     = (& $getProp $Item 'Description')
					Hidden          = [bool](& $getProp $Item 'Hidden')
					ContentType     = (& $getProp $Item 'ContentType')
					IsDependency    = $IsDependency
					Definition      = $null
					DataSources     = @()
					SharedDataSets  = @()
					DataSetSourceRefs = @()
					Link            = $null
					Policy          = $null
					LocalFile       = $null
				}
				$sourceByPath[$path] = $entry
				$sourceById[$entry.Id] = $entry
				return $entry
			}

			$rootFolders = @{}
			foreach ($r in $roots)
			{
				$rp = $r
				if ($rp -eq '') { $rp = '/' }
				try
				{
					$rf = & $srcCall "Folders$(ConvertTo-sqmSsrsPathKey $rp)"
					$rootFolders[$r] = $rf
				}
				catch
				{
					if ($_.Exception.Data['StatusCode'] -eq 404) { throw "Quellordner '$rp' existiert auf $srcApi nicht." }
					throw
				}

				$queue = [System.Collections.Generic.Queue[string]]::new()
				$queue.Enqueue($rp)
				while ($queue.Count -gt 0)
				{
					$current = $queue.Dequeue()
					$children = @((& $srcCall "Folders$(ConvertTo-sqmSsrsPathKey $current)/CatalogItems").value)
					foreach ($c in $children)
					{
						if ([string]$c.Type -eq 'Folder')
						{
							$folders.Add($c)
							$queue.Enqueue([string]$c.Path)
						}
						else
						{
							$null = & $registerItem $c $false
						}
					}
				}
			}

			$byType = @($sourceByPath.Values | Group-Object Type | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
			& $addStep 'Inventar Quelle' 'Success' "$($folders.Count) Ordner; $byType"

			# ==============================================================
			# 3. Details und Referenzen
			# ==============================================================
			$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "sqmSsrsMig_$timestamp"
			$null = New-Item -ItemType Directory -Path $tempDir -Force -WhatIf:$false

			$pendingDeps = [System.Collections.Generic.Queue[string]]::new()
			$missingRefs = [System.Collections.Generic.List[string]]::new()
			$noteRef = {
				param ([string]$RefPath, [string]$From)
				if ([string]::IsNullOrEmpty($RefPath)) { return }
				if ($sourceByPath.ContainsKey($RefPath)) { return }
				if ($null -ne (& $rootOf $RefPath)) { $missingRefs.Add("$From -> $RefPath"); return }
				if (-not $SkipDependencies) { $pendingDeps.Enqueue("$RefPath|$From") }
			}

			# Absolute Referenzpfade in RDL/RSD; relative bleiben relativ zum Ordner des Elements.
			$resolveRef = {
				param ([string]$Ref, [string]$ItemPath)
				if ([string]::IsNullOrWhiteSpace($Ref)) { return $null }
				if ($Ref.StartsWith('/')) { return $Ref }
				$base = & $parentOf $ItemPath
				$parts = [System.Collections.Generic.List[string]]::new()
				foreach ($seg in @(($base.Trim('/') -split '/') + ($Ref -split '/')))
				{
					if ($seg -eq '' -or $seg -eq '.') { continue }
					if ($seg -eq '..') { if ($parts.Count -gt 0) { $parts.RemoveAt($parts.Count - 1) }; continue }
					$parts.Add($seg)
				}
				return '/' + ($parts -join '/')
			}

			$loadDetails = {
				param ($Entry)
				switch ($Entry.Type)
				{
					'DataSource'
					{
						$Entry.Definition = & $srcCall "DataSources($($Entry.Id))"
					}
					'Report'
					{
						$Entry.DataSources = @((& $srcCall "Reports($($Entry.Id))/DataSources").value)
						foreach ($ds in $Entry.DataSources)
						{
							if ((& $getProp $ds 'IsReference') -eq $true)
							{
								& $noteRef ([string](& $getProp $ds 'Path')) $Entry.Path
							}
						}
						try
						{
							$Entry.SharedDataSets = @((& $srcCall "Reports($($Entry.Id))/SharedDataSets").value)
							foreach ($sd in $Entry.SharedDataSets) { & $noteRef ([string]$sd.Path) $Entry.Path }
						}
						catch
						{
							& $addStep "Datasets lesen: $($Entry.Path)" 'Warning' $_.Exception.Message
						}
					}
					'DataSet'
					{
						$file = Join-Path $tempDir "$($Entry.Id).rsd"
						& $srcCall "CatalogItems($($Entry.Id))/Content/`$value" -OutFile $file
						$text = [System.IO.File]::ReadAllText($file)
						$refs = @([regex]::Matches($text, '<DataSourceReference>([^<]*)</DataSourceReference>') | ForEach-Object {
								& $resolveRef ([System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value)) $Entry.Path
							})
						# Die Bindung im Katalog hat Vorrang vor dem Text in der RSD.
						try
						{
							$bound = @((& $srcCall "DataSets($($Entry.Id))/DataSources").value)
							$boundRefs = @($bound | Where-Object { (& $getProp $_ 'IsReference') -eq $true } | ForEach-Object { [string](& $getProp $_ 'Path') } | Where-Object { $_ })
							if ($boundRefs.Count -gt 0) { $refs = $boundRefs }
							$Entry.DataSources = $bound
						}
						catch { }
						$Entry.DataSetSourceRefs = @($refs | Where-Object { $_ })
						foreach ($ref in $Entry.DataSetSourceRefs) { & $noteRef $ref $Entry.Path }
					}
					'LinkedReport'
					{
						$lr = & $srcCall "LinkedReports($($Entry.Id))"
						$Entry.Link = [string](& $getProp $lr 'Link')
						& $noteRef $Entry.Link $Entry.Path
					}
				}
			}

			foreach ($e in @($sourceByPath.Values))
			{
				if ($ItemType -notcontains $e.Type -and $e.Type -in @('DataSource', 'DataSet', 'Report', 'LinkedReport', 'Resource', 'PowerBIReport', 'ExcelWorkbook')) { continue }
				try { & $loadDetails $e }
				catch { & $addStep "Details: $($e.Path)" 'Failed' $_.Exception.Message }
			}

			# Abhaengigkeiten ausserhalb der Ordner nachladen (koennen selbst wieder referenzieren).
			$depCount = 0
			while ($pendingDeps.Count -gt 0)
			{
				$pair = $pendingDeps.Dequeue() -split '\|', 2
				$depPath = $pair[0]
				if ($sourceByPath.ContainsKey($depPath)) { continue }
				try
				{
					$dep = & $srcCall "CatalogItems$(ConvertTo-sqmSsrsPathKey $depPath)"
					$entry = & $registerItem $dep $true
					$depCount++
					& $loadDetails $entry
				}
				catch
				{
					if ($_.Exception.Data['StatusCode'] -eq 404) { $missingRefs.Add("$($pair[1]) -> $depPath") }
					else { & $addStep "Abhaengigkeit: $depPath" 'Failed' $_.Exception.Message }
				}
			}
			if ($depCount -gt 0)
			{
				& $addStep 'Abhaengigkeiten' 'Success' "$depCount Element(e) ausserhalb der Quellordner werden am gleichen Pfad mitgenommen."
			}
			foreach ($m in $missingRefs)
			{
				& $addStep 'Referenz ins Leere' 'Warning' "$m - existiert schon auf der Quelle nicht; der Bericht laeuft auch dort nicht."
			}

			if ($IncludeSecurity)
			{
				$secTargets = @($folders) + @($sourceByPath.Values)
				foreach ($rk in $rootFolders.Keys) { if ($rk -ne '') { $secTargets += $rootFolders[$rk] } }
				$policyCount = 0
				foreach ($t in $secTargets)
				{
					try
					{
						$pol = & $srcCall "CatalogItems($($t.Id))/Policies"
						if ((& $getProp $pol 'InheritParentPolicy') -eq $false)
						{
							if ($sourceByPath.ContainsKey([string]$t.Path)) { $sourceByPath[[string]$t.Path].Policy = $pol }
							else { $t | Add-Member -NotePropertyName sqmPolicy -NotePropertyValue $pol -Force }
							$policyCount++
						}
					}
					catch { & $addStep "Rechte lesen: $($t.Path)" 'Warning' $_.Exception.Message }
				}
				& $addStep 'Rechte Quelle' 'Success' "$policyCount Element(e) mit eigenen Rechten (ohne Vererbung)."
			}

			# Abonnements: nur auflisten.
			try
			{
				$allSubs = @((& $srcCall 'Subscriptions').value)
				foreach ($s in $allSubs)
				{
					$rp = [string](& $getProp $s 'Report')
					if ($rp -and $sourceByPath.ContainsKey($rp) -and -not $sourceByPath[$rp].IsDependency)
					{
						$subscriptions.Add([PSCustomObject]@{
								Report            = $rp
								Description       = (& $getProp $s 'Description')
								Owner             = (& $getProp $s 'Owner')
								DeliveryExtension = (& $getProp $s 'DeliveryExtension')
								IsDataDriven      = (& $getProp $s 'IsDataDriven')
								LastStatus        = (& $getProp $s 'LastStatus')
							})
					}
				}
				if ($subscriptions.Count -gt 0)
				{
					& $addStep 'Abonnements' 'Warning' "$($subscriptions.Count) Abonnement(s) auf migrierten Berichten werden nicht uebernommen und muessen auf dem Ziel neu angelegt werden (Liste im Bericht)."
				}
			}
			catch { & $addStep 'Abonnements' 'Warning' "Konnten nicht gelesen werden: $($_.Exception.Message)" }

			# ==============================================================
			# 4. Plan gegen das Ziel
			# ==============================================================
			$typeOrder = @{ DataSource = 1; DataSet = 2; Resource = 3; Report = 4; LinkedReport = 5; PowerBIReport = 6; ExcelWorkbook = 7 }
			$plan = [System.Collections.Generic.List[PSCustomObject]]::new()

			$destLookup = {
				param ([string]$Path)
				try { return (& $dstCall "CatalogItems$(ConvertTo-sqmSsrsPathKey $Path)") }
				catch
				{
					if ($_.Exception.Data['StatusCode'] -eq 404) { return $null }
					throw
				}
			}

			foreach ($e in @($sourceByPath.Values | Sort-Object @{ Expression = { $o = $typeOrder[$_.Type]; if ($null -eq $o) { 99 } else { $o } } }, Path))
			{
				$destPath = & $mapPath $e.Path
				$p = [PSCustomObject]@{
					Type            = $e.Type
					SourcePath      = $e.Path
					DestinationPath = $destPath
					Action          = ''
					Status          = 'Planned'
					Detail          = ''
					DestinationId   = $null
					MissingSecret   = $false
					Source          = $e
				}
				if (-not $typeOrder.ContainsKey($e.Type))
				{
					$p.Action = 'NotSupported'; $p.Status = 'NotSupported'
					$p.Detail = "Typ '$($e.Type)' wird nicht migriert."
				}
				elseif ($ItemType -notcontains $e.Type)
				{
					$p.Action = 'Excluded'; $p.Status = 'Skipped'; $p.Detail = 'Durch -ItemType ausgeschlossen.'
				}
				else
				{
					$existing = & $destLookup $destPath
					if ($existing)
					{
						$p.DestinationId = [string]$existing.Id
						if ([string]$existing.Type -ne $e.Type)
						{
							$p.Action = 'Conflict'; $p.Status = 'Failed'
							$p.Detail = "Auf dem Ziel existiert unter diesem Pfad ein Element vom Typ '$($existing.Type)'."
						}
						elseif ($e.Type -eq 'DataSource' -and -not $OverwriteDataSources)
						{
							$p.Action = 'Skip'; $p.Detail = 'Datenquelle existiert auf dem Ziel und bleibt unveraendert (-OverwriteDataSources zum Ersetzen).'
						}
						elseif ($e.Type -ne 'DataSource' -and -not $Overwrite)
						{
							$p.Action = 'Skip'; $p.Detail = 'Existiert auf dem Ziel (-Overwrite zum Ersetzen).'
						}
						else { $p.Action = 'Overwrite' }
					}
					else { $p.Action = 'Create' }
				}

				# Kennwortpruefung fuer gespeicherte Anmeldeinformationen
				$credUsers = @()
				if ($e.Type -eq 'DataSource' -and $e.Definition -and $p.Action -in @('Create', 'Overwrite'))
				{
					if ([string](& $getProp $e.Definition 'CredentialRetrieval') -ieq 'Store')
					{
						$credUsers += [string](& $getProp (& $getProp $e.Definition 'CredentialsInServer') 'UserName')
					}
				}
				if ($e.Type -eq 'Report' -and $p.Action -in @('Create', 'Overwrite'))
				{
					foreach ($ds in $e.DataSources)
					{
						if ((& $getProp $ds 'IsReference') -ne $true -and [string](& $getProp $ds 'CredentialRetrieval') -ieq 'Store')
						{
							$credUsers += [string](& $getProp (& $getProp $ds 'CredentialsInServer') 'UserName')
						}
					}
				}
				$missing = @($credUsers | Where-Object { $_ -and -not (& $findSecret $_) } | Select-Object -Unique)
				if ($missing.Count -gt 0)
				{
					$p.MissingSecret = $true
					$p.Detail = (("$($p.Detail) Gespeichertes Kennwort fuer '$($missing -join "', '")' fehlt (-DataSourceCredential); es laesst sich von der Quelle nicht auslesen.").Trim())
					& $addStep "Kennwort: $($e.Path)" 'Warning' "Gespeicherte Anmeldeinformationen fuer '$($missing -join "', '")' - ohne -DataSourceCredential kann die Datenquelle auf dem Ziel keine Verbindung herstellen."
				}

				$plan.Add($p)
			}

			foreach ($p in $plan)
			{
				$items.Add([PSCustomObject]@{
						Type            = $p.Type
						SourcePath      = $p.SourcePath
						DestinationPath = $p.DestinationPath
						Action          = $p.Action
						Status          = $p.Status
						Detail          = $p.Detail
					})
			}
			$result.ItemCount = $plan.Count

			$planSummary = @($plan | Group-Object Action | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
			& $addStep 'Plan' 'Success' $planSummary

			if ($AssessOnly)
			{
				$result.Status = 'Assessed'
				$conflicts = @($plan | Where-Object { $_.Action -eq 'Conflict' })
				if ($conflicts.Count -gt 0)
				{
					$result.Status = 'Blocked'
					$result.Reason = "$($conflicts.Count) Typkonflikt(e) auf dem Ziel."
				}
				else { $result.Reason = "Bewertung abgeschlossen: $planSummary." }
			}
			else
			{
				$work = @($plan | Where-Object { $_.Action -in @('Create', 'Overwrite') })
				$doIt = $PSCmdlet.ShouldProcess($dstApi, "$($work.Count) Element(e) aus '$($result.SourceFolder -join ', ')' migrieren")
				if (-not $doIt)
				{
					foreach ($p in $work) { $p.Status = 'WhatIf' }
					& $addStep 'Migration' 'WhatIf' "Es wurde nichts geaendert. Geplant: $planSummary."
				}
				else
				{
					# ==============================================================
					# 5. Export der Quelle, Sicherung der Ziel-Elemente
					# ==============================================================
					$runDir = Join-Path $OutputPath "SsrsMigration_$timestamp"
					$exportDir = Join-Path $runDir 'Source'
					$backupDir = Join-Path $runDir 'DestinationBackup'
					$null = New-Item -ItemType Directory -Path $exportDir -Force
					$result.ExportPath = $runDir

					foreach ($p in $plan)
					{
						$e = $p.Source
						try
						{
							if ($extensionFor.ContainsKey($e.Type))
							{
								$file = & $localPath $exportDir $e.Path $extensionFor[$e.Type]
								& $srcCall "CatalogItems($($e.Id))/Content/`$value" -OutFile $file
								$e.LocalFile = $file
							}
							else
							{
								$file = & $localPath $exportDir $e.Path '.json'
								$def = [ordered]@{ Item = $e.Path; Type = $e.Type; Definition = $e.Definition; DataSources = $e.DataSources; Link = $e.Link }
								[System.IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $def -Depth 10), [System.Text.UTF8Encoding]::new($false))
							}
						}
						catch
						{
							$p.Status = 'Failed'; $p.Detail = "Export: $($_.Exception.Message)"
						}

						if ($p.Action -eq 'Overwrite' -and $p.Status -ne 'Failed')
						{
							try
							{
								if ($extensionFor.ContainsKey($e.Type))
								{
									$bfile = & $localPath $backupDir $p.DestinationPath $extensionFor[$e.Type]
									& $dstCall "CatalogItems($($p.DestinationId))/Content/`$value" -OutFile $bfile
								}
								elseif ($e.Type -eq 'DataSource')
								{
									$bfile = & $localPath $backupDir $p.DestinationPath '.json'
									$bdef = & $dstCall "DataSources($($p.DestinationId))"
									[System.IO.File]::WriteAllText($bfile, (ConvertTo-Json -InputObject $bdef -Depth 10), [System.Text.UTF8Encoding]::new($false))
								}
							}
							catch
							{
								$p.Status = 'Failed'; $p.Detail = "Sicherung des Ziel-Elements fehlgeschlagen, nicht ueberschrieben: $($_.Exception.Message)"
							}
						}
					}
					& $addStep 'Export' 'Success' "Quellinhalt nach '$exportDir' exportiert."

					# ==============================================================
					# 6. Ordner anlegen
					# ==============================================================
					$folderPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
					foreach ($f in $folders) { $null = $folderPaths.Add((& $mapPath ([string]$f.Path))) }
					foreach ($p in $work) { $null = $folderPaths.Add((& $parentOf $p.DestinationPath)) }
					if ($null -ne $destRoot -and $destRoot -ne '') { $null = $folderPaths.Add($destRoot) }

					# Jede Ebene einzeln, damit auch Zwischenordner entstehen.
					$allLevels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
					foreach ($fp in $folderPaths)
					{
						$acc = ''
						foreach ($seg in ($fp.Trim('/') -split '/'))
						{
							if ($seg -eq '') { continue }
							$acc = "$acc/$seg"
							$null = $allLevels.Add($acc)
						}
					}
					$createdFolders = 0
					$folderErrors = 0
					foreach ($fp in @($allLevels | Sort-Object { ($_ -split '/').Count }, { $_ }))
					{
						try
						{
							$ex = & $destLookup $fp
							if ($ex)
							{
								if ([string]$ex.Type -ne 'Folder') { throw "Unter '$fp' existiert ein Element vom Typ '$($ex.Type)'." }
								continue
							}
							$name = ($fp -split '/')[-1]
							$null = & $dstCall 'Folders' 'POST' @{ Name = $name; Path = $fp }
							$createdFolders++
						}
						catch
						{
							$folderErrors++
							& $addStep "Ordner: $fp" 'Failed' $_.Exception.Message
						}
					}
					& $addStep 'Ordner' $(if ($folderErrors) { 'Warning' } else { 'Success' }) "$createdFolders angelegt, $($allLevels.Count - $createdFolders - $folderErrors) vorhanden, $folderErrors Fehler."

					# ==============================================================
					# 7. Elemente schreiben
					# ==============================================================
					# Referenzen im Inhalt umschreiben (nur absolute Pfade in migrierten Ordnern).
					$rewriteContent = {
						param ([byte[]]$Bytes)
						if ($null -eq $destRoot) { return $Bytes }
						$enc = New-Object System.Text.UTF8Encoding($false)
						$hasBom = ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
						$text = $enc.GetString($Bytes)
						if ($hasBom) { $text = $text.Substring(1) }
						$new = [regex]::Replace($text, '<(DataSourceReference|SharedDataSetReference)>([^<]*)</\1>', {
								param ($m)
								$val = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value)
								if (-not $val.StartsWith('/')) { return $m.Value }
								$mapped = & $mapPath $val
								if ($mapped -eq $val) { return $m.Value }
								return "<$($m.Groups[1].Value)>$([System.Security.SecurityElement]::Escape($mapped))</$($m.Groups[1].Value)>"
							})
						if ($new -eq $text) { return $Bytes }
						$out = $enc.GetBytes($new)
						if ($hasBom) { $out = [byte[]](@(0xEF, 0xBB, 0xBF) + $out) }
						return $out
					}

					$credentialsBlock = {
						param ($Def)
						$retrieval = ([string](& $getProp $Def 'CredentialRetrieval')).ToLowerInvariant()
						$block = @{}
						if ($retrieval -ieq 'Store')
						{
							$cis = & $getProp $Def 'CredentialsInServer'
							$user = [string](& $getProp $cis 'UserName')
							$secret = & $findSecret $user
							$pw = $null
							if ($secret) { $pw = & $toPlain $secret.Password }
							$block['CredentialsInServer'] = @{
								UserName                     = $user
								Password                     = $pw
								UseAsWindowsCredentials      = [bool](& $getProp $cis 'UseAsWindowsCredentials')
								ImpersonateAuthenticatedUser = [bool](& $getProp $cis 'ImpersonateAuthenticatedUser')
							}
						}
						elseif ($retrieval -ieq 'Prompt')
						{
							$cbu = & $getProp $Def 'CredentialsByUser'
							$block['CredentialsByUser'] = @{
								DisplayText             = [string](& $getProp $cbu 'DisplayText')
								UseAsWindowsCredentials = [bool](& $getProp $cbu 'UseAsWindowsCredentials')
							}
						}
						return $block
					}

					foreach ($p in $work)
					{
						if ($p.Status -eq 'Failed') { continue }
						$e = $p.Source
						try
						{
							$payload = [ordered]@{
								'@odata.type' = "#Model.$($e.Type)"
								Name          = $e.Name
								Path          = $p.DestinationPath
								Description   = $e.Description
								Hidden        = $e.Hidden
							}
							if ($e.Type -eq 'DataSource')
							{
								$def = $e.Definition
								$cs = & $mapConnection ([string](& $getProp $def 'ConnectionString'))
								$payload['ConnectionString'] = $cs
								# Ohne IsConnectionStringOverridden=true verwirft SSRS die Verbindungszeichenfolge
								# beim Anlegen und Aendern kommentarlos (HTTP 201, Datenquelle danach leer).
								if (-not [string]::IsNullOrEmpty($cs)) { $payload['IsConnectionStringOverridden'] = $true }
								$payload['DataSourceType'] = [string](& $getProp $def 'DataSourceType')
								# Die API nimmt die Werte nur klein geschrieben an ('Store' -> HTTP 400).
								$payload['CredentialRetrieval'] = ([string](& $getProp $def 'CredentialRetrieval')).ToLowerInvariant()
								$enabled = & $getProp $def 'IsEnabled'
								$payload['IsEnabled'] = ($null -eq $enabled -or [bool]$enabled)
								$cb = & $credentialsBlock $def
								foreach ($k in $cb.Keys) { $payload[$k] = $cb[$k] }
							}
							elseif ($e.Type -eq 'LinkedReport')
							{
								$payload['Link'] = & $mapPath $e.Link
								# /LinkedReports erwartet als Path den Elternordner, alle anderen Typen den
								# vollstaendigen Pfad des neuen Elements.
								$payload['Path'] = & $parentOf $p.DestinationPath
							}
							else
							{
								$bytes = [System.IO.File]::ReadAllBytes($e.LocalFile)
								if ($e.Type -in @('Report', 'DataSet')) { $bytes = & $rewriteContent $bytes }
								$payload['Content'] = [System.Convert]::ToBase64String($bytes)
								$ct = $e.ContentType
								if (-not $ct) { $ct = '' }
								$payload['ContentType'] = $ct
							}

							$endpoint = $endpointFor[$e.Type]
							if ($p.Action -eq 'Overwrite')
							{
								$payload.Remove('Path')
								$null = & $dstCall "$endpoint($($p.DestinationId))" 'PATCH' $payload
								$p.Status = 'Success'; $p.Detail = (("$($p.Detail) Ueberschrieben (ID bleibt).").Trim())
							}
							else
							{
								$created = & $dstCall $endpoint 'POST' $payload
								$newId = & $getProp $created 'Id'
								if (-not $newId)
								{
									$chk = & $destLookup $p.DestinationPath
									if ($chk) { $newId = $chk.Id }
								}
								if (-not $newId) { throw "Angelegt gemeldet, aber unter '$($p.DestinationPath)' nicht auffindbar." }
								$p.DestinationId = [string]$newId
								$p.Status = 'Success'
							}
							if ($p.MissingSecret) { $p.Status = 'Warning' }
						}
						catch
						{
							$p.Status = 'Failed'
							$p.Detail = (("$($p.Detail) $($_.Exception.Message)").Trim())
						}
					}
					$okCount = @($work | Where-Object { $_.Status -eq 'Success' }).Count
					$errCount = @($work | Where-Object { $_.Status -eq 'Failed' }).Count
					& $addStep 'Elemente' $(if ($errCount) { 'Warning' } else { 'Success' }) "$okCount geschrieben, $errCount Fehler."

					# ==============================================================
					# 8. Datenquellen-Bindungen aus dem Quellkatalog uebertragen
					# ==============================================================
					$bindingFor = {
						param ($SourceDataSources)
						$list = [System.Collections.Generic.List[object]]::new()
						foreach ($ds in @($SourceDataSources))
						{
							if ((& $getProp $ds 'IsReference') -eq $true)
							{
								$list.Add([ordered]@{
										Name        = [string]$ds.Name
										IsReference = $true
										Path        = & $mapPath ([string](& $getProp $ds 'Path'))
									})
							}
							else
							{
								# Gespeichertes Kennwort unbekannt: Eintrag weglassen, sonst wuerde der PUT die
								# Anmeldedaten mit leerem Kennwort ueberschreiben. Gewarnt wurde schon im Plan.
								if (([string](& $getProp $ds 'CredentialRetrieval')) -ieq 'store' -and
									-not (& $findSecret ([string](& $getProp (& $getProp $ds 'CredentialsInServer') 'UserName'))))
								{
									continue
								}
								$origCs = [string](& $getProp $ds 'ConnectionString')
								$entry = [ordered]@{
									Name                = [string]$ds.Name
									IsReference         = $false
									ConnectionString    = & $mapConnection $origCs
									DataSourceType      = [string](& $getProp $ds 'DataSourceType')
									CredentialRetrieval = ([string](& $getProp $ds 'CredentialRetrieval')).ToLowerInvariant()
									IsEnabled           = $true
								}
								if ([bool](& $getProp $ds 'IsConnectionStringOverridden') -or $entry.ConnectionString -ne $origCs)
								{
									$entry['IsConnectionStringOverridden'] = $true
								}
								$cb = & $credentialsBlock $ds
								foreach ($k in $cb.Keys) { $entry[$k] = $cb[$k] }
								$list.Add($entry)
							}
						}
						return , $list
					}

					$bindOk = 0; $bindErr = 0
					foreach ($p in @($work | Where-Object { $_.Status -in @('Success', 'Warning') -and $_.Type -in @('Report', 'DataSet') }))
					{
						$e = $p.Source
						if (@($e.DataSources).Count -eq 0) { continue }
						$segment = 'Reports'
						if ($e.Type -eq 'DataSet') { $segment = 'DataSets' }
						try
						{
							$binding = & $bindingFor $e.DataSources
							$null = & $dstCall "$segment($($p.DestinationId))/DataSources" 'PUT' (ConvertTo-Json -InputObject @($binding) -Depth 10 -Compress)
							$bindOk++
						}
						catch
						{
							$bindErr++
							$p.Status = 'Warning'
							$p.Detail = (("$($p.Detail) Bindung der Datenquellen fehlgeschlagen: $($_.Exception.Message)").Trim())
						}
					}
					if ($bindOk + $bindErr -gt 0)
					{
						& $addStep 'Datenquellen-Bindungen' $(if ($bindErr) { 'Warning' } else { 'Success' }) "$bindOk gesetzt, $bindErr Fehler."
					}

					# ==============================================================
					# 9. Rechte
					# ==============================================================
					if ($IncludeSecurity)
					{
						$secOk = 0; $secErr = 0
						$secItems = [System.Collections.Generic.List[object]]::new()
						foreach ($f in $folders) { if ($f.PSObject.Properties['sqmPolicy']) { $secItems.Add(@((& $mapPath ([string]$f.Path)), $f.sqmPolicy)) } }
						foreach ($rk in $rootFolders.Keys)
						{
							$rf = $rootFolders[$rk]
							if ($rf.PSObject.Properties['sqmPolicy'])
							{
								$target = & $mapPath ([string]$rf.Path)
								$secItems.Add(@($target, $rf.sqmPolicy))
							}
						}
						foreach ($p in $work) { if ($p.Status -ne 'Failed' -and $p.Source.Policy) { $secItems.Add(@($p.DestinationPath, $p.Source.Policy)) } }

						foreach ($si in $secItems)
						{
							try
							{
								$tgt = & $destLookup $si[0]
								if (-not $tgt) { throw "Ziel '$($si[0])' nicht gefunden." }
								$body = @{
									InheritParentPolicy = $false
									Policies            = @(@($si[1].Policies) | ForEach-Object {
											@{
												GroupUserName = [string]$_.GroupUserName
												Roles         = @(@($_.Roles) | ForEach-Object { @{ Name = [string]$_.Name; Description = [string](& $getProp $_ 'Description') } })
											}
										})
								}
								$null = & $dstCall "CatalogItems($($tgt.Id))/Policies" 'PUT' $body
								$secOk++
							}
							catch
							{
								$secErr++
								& $addStep "Rechte: $($si[0])" 'Failed' $_.Exception.Message
							}
						}
						& $addStep 'Rechte' $(if ($secErr) { 'Warning' } else { 'Success' }) "$secOk Element(e) gesetzt, $secErr Fehler."
					}

					# ==============================================================
					# 10. Pruefung: Bindungen vom Ziel zuruecklesen
					# ==============================================================
					$verifyErr = 0
					foreach ($p in @($work | Where-Object { $_.Status -in @('Success', 'Warning') -and $_.Type -eq 'Report' }))
					{
						try
						{
							$actual = @((& $dstCall "Reports($($p.DestinationId))/DataSources").value)
							$problems = [System.Collections.Generic.List[string]]::new()
							foreach ($src in @($p.Source.DataSources))
							{
								$a = $actual | Where-Object { $_.Name -eq $src.Name } | Select-Object -First 1
								if (-not $a) { $problems.Add("'$($src.Name)' fehlt"); continue }
								if ((& $getProp $src 'IsReference') -eq $true)
								{
									$expected = & $mapPath ([string](& $getProp $src 'Path'))
									$got = [string](& $getProp $a 'Path')
									if ($got -ne $expected) { $problems.Add("'$($src.Name)' zeigt auf '$got' statt '$expected'") }
								}
							}
							if ($problems.Count -gt 0)
							{
								$verifyErr++
								$p.Status = 'Warning'
								$p.Detail = (("$($p.Detail) Pruefung: $($problems -join '; ').").Trim())
							}
						}
						catch
						{
							$verifyErr++
							$p.Status = 'Warning'
							$p.Detail = (("$($p.Detail) Pruefung nicht moeglich: $($_.Exception.Message)").Trim())
						}
					}
					& $addStep 'Pruefung' $(if ($verifyErr) { 'Warning' } else { 'Success' }) "Bindungen zurueckgelesen, $verifyErr Bericht(e) mit Abweichung."

				}

				# Status der Plan-Eintraege ins Ergebnis uebernehmen
				for ($i = 0; $i -lt $plan.Count; $i++)
				{
					if ($plan[$i].Status -eq 'Planned' -and $plan[$i].Action -eq 'Skip') { $plan[$i].Status = 'Skipped' }
					$items[$i].Status = $plan[$i].Status
					$items[$i].Detail = $plan[$i].Detail
				}

				if ($result.Status -eq 'Unknown')
				{
					$failedItems = @($items | Where-Object { $_.Status -eq 'Failed' })
					$failedSteps = @($steps | Where-Object { $_.Status -eq 'Failed' })
					if (@($steps | Where-Object { $_.Status -eq 'WhatIf' }).Count -gt 0)
					{
						$result.Status = 'WhatIf'
						$result.Reason = 'WhatIf-Lauf, es wurde nichts geaendert.'
					}
					elseif ($failedItems.Count -gt 0 -or $failedSteps.Count -gt 0)
					{
						$result.Status = 'Failed'
						$result.Reason = "$($failedItems.Count) Element(e) und $($failedSteps.Count) Schritt(e) fehlgeschlagen."
					}
					elseif (@($items | Where-Object { $_.Status -eq 'Warning' }).Count -gt 0 -or @($steps | Where-Object { $_.Status -eq 'Warning' }).Count -gt 0)
					{
						$result.Status = 'Warning'
						$result.Reason = 'Migration abgeschlossen, Hinweise beachten.'
					}
					else
					{
						$result.Status = 'Success'
						$result.Reason = "$(@($items | Where-Object { $_.Status -eq 'Success' }).Count) Element(e) migriert."
					}
				}
			}
		}
		catch
		{
			$result.Status = 'Failed'
			$result.Reason = $_.Exception.Message
			& $addStep 'Abbruch' 'Failed' $_.Exception.Message
			if ($EnableException)
			{
				if ($tempDir -and (Test-Path -LiteralPath $tempDir)) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false }
				throw
			}
		}
		finally
		{
			if ($tempDir -and (Test-Path -LiteralPath $tempDir)) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false }
		}

		# ==============================================================
		# 11. Bericht
		# ==============================================================
		if (-not $NoReport)
		{
			try
			{
				if (-not (Test-Path -LiteralPath $OutputPath)) { $null = New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop -WhatIf:$false }
				$reportFile = Join-Path $OutputPath "SsrsMigration_$timestamp.html"
				$bodyHtml = & $buildReportBody $result $steps
				$html = ConvertTo-sqmHtmlReport -Title 'SSRS-Migration' `
					-Subtitle "$srcApi  ->  $dstApi   ($($result.Action), Status: $($result.Status))" `
					-BodyHtml $bodyHtml
				[System.IO.File]::WriteAllText($reportFile, $html, [System.Text.UTF8Encoding]::new($false))
				$result.ReportFile = $reportFile
				Invoke-sqmOpenReport -HtmlFile $reportFile -NoOpen:$NoOpen
			}
			catch
			{
				Invoke-sqmLogging -Message "Bericht konnte nicht geschrieben werden: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
			}
		}

		return $result
	}
}
