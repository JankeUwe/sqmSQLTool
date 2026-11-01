<#
.SYNOPSIS
    Liest alle sys.configurations-Optionen und globalen Trace Flags einer Instanz.

.DESCRIPTION
    Gemeinsame Grundlage fuer Compare-sqmServerConfiguration -AllConfigOptions, Save-sqmConfigBaseline und
    Compare-sqmConfigBaseline. sys.configurations liefert alle Optionen (auch die advanced), unabhaengig von
    'show advanced options'. Liefert pro Option value (konfiguriert), value_in_use (aktiv), is_dynamic und
    is_advanced. Trace Flags kommen aus DBCC TRACESTATUS(-1); schlaegt das fehl, ist TraceFlagsRead $false und
    der Vergleich ueberspringt Trace Flags.

.PARAMETER SqlInstance
    Instanz, die gelesen wird.

.PARAMETER SqlCredential
    Optionale SQL-Anmeldung.

.PARAMETER Label
    Optionale Bezeichnung, wird in den Metadaten abgelegt.
#>
function Get-sqmConfigOptionSet
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$Label
	)

	$optionQuery = @"
SELECT configuration_id AS ConfigurationId,
       name             AS Name,
       CONVERT(bigint, value)        AS Value,
       CONVERT(bigint, value_in_use) AS ValueInUse,
       CONVERT(int, is_dynamic)      AS IsDynamic,
       CONVERT(int, is_advanced)     AS IsAdvanced
FROM sys.configurations
ORDER BY configuration_id
"@
	$metaQuery = @"
SELECT CONVERT(nvarchar(128), SERVERPROPERTY('ServerName'))    AS ServerName,
       CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')) AS ProductVersion,
       CONVERT(nvarchar(128), SERVERPROPERTY('Edition'))        AS Edition
"@

	$options = @(Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Query $optionQuery -As PSObject -EnableException)
	$meta = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Query $metaQuery -As PSObject -EnableException |
		Select-Object -First 1

	$flagsRead = $true
	$flags = @()
	try
	{
		$flags = @(Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Query 'DBCC TRACESTATUS(-1) WITH NO_INFOMSGS' -As PSObject -EnableException |
				Where-Object { $_.Global -eq 1 } | ForEach-Object { [int]$_.TraceFlag } | Sort-Object)
	}
	catch
	{
		$flagsRead = $false
		Write-Verbose "Trace Flags von '$SqlInstance' nicht lesbar: $($_.Exception.Message)"
	}

	$productVersion = [string]$meta.ProductVersion
	$major = 0
	[void][int]::TryParse(($productVersion -split '\.')[0], [ref]$major)

	[PSCustomObject]@{
		Meta           = [PSCustomObject]@{
			ServerName     = [string]$meta.ServerName
			SqlInstance    = $SqlInstance
			ProductVersion = $productVersion
			MajorVersion   = $major
			Edition        = [string]$meta.Edition
			CapturedAt     = (Get-Date -Format 'o')
			Label          = $Label
		}
		Options        = @($options | ForEach-Object {
				[PSCustomObject]@{
					ConfigurationId = [int]$_.ConfigurationId
					Name            = [string]$_.Name
					Value           = [int64]$_.Value
					ValueInUse      = [int64]$_.ValueInUse
					IsDynamic       = [bool]$_.IsDynamic
					IsAdvanced      = [bool]$_.IsAdvanced
				}
			})
		TraceFlags     = @($flags)
		TraceFlagsRead = $flagsRead
	}
}

<#
.SYNOPSIS
    Vergleicht zwei mit Get-sqmConfigOptionSet gelesene (oder aus einer Baseline geladene) Zustaende.

.DESCRIPTION
    Pro Abweichung eine Zeile mit Category, Setting, SourceValue, TargetValue, Status und DriftType.
    - 'value_in_use differs': aktiver Wert unterscheidet sich (Critical bei sicherheitsrelevanten Optionen).
    - 'pending (RECONFIGURE)' / 'pending (restart)': konfigurierter Wert weicht vom aktiven ab, je nach is_dynamic.
    - 'missing' : Option existiert nur auf einer Seite. Haben beide Seiten unterschiedliche Hauptversionen, werden
      solche Optionen uebersprungen (Version-only), weil sie kein Drift sind.
    - 'trace flag': globales Trace Flag nur auf einer Seite (nur wenn beide Seiten gelesen werden konnten).
    - Ausstehend wird nur gemeldet, wenn sich der Pending-Zustand zwischen den Seiten unterscheidet (konfiguriert 0 /
      aktiv 16 bei 'min server memory (MB)' ist dauerhaft normal).
    Standardmaessig ignoriert: 'version high part', 'version low part' (aendern sich mit dem Build) und
    'show advanced options' (reiner Anzeigeschalter ohne Wirkung auf den Betrieb).

.PARAMETER Reference
    Referenzzustand (Source bzw. Baseline).

.PARAMETER Difference
    Zu pruefender Zustand (Target bzw. aktuelle Instanz).

.PARAMETER IgnoreOption
    Optionsnamen (Wildcards erlaubt), die nicht verglichen werden.
#>
function Compare-sqmConfigOptionSet
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		$Reference,
		[Parameter(Mandatory = $true)]
		$Difference,
		[Parameter(Mandatory = $false)]
		[string[]]$IgnoreOption = @()
	)

	$ignore = @('version high part*', 'version low part*', 'show advanced options') + @($IgnoreOption)
	$securityRelevant = @('xp_cmdshell', 'Ole Automation Procedures', 'Ad Hoc Distributed Queries', 'clr enabled',
		'clr strict security', 'cross db ownership chaining', 'scan for startup procs', 'external scripts enabled')
	$rows = [System.Collections.Generic.List[PSCustomObject]]::new()

	function _Row
	{
		param ([string]$Category, [string]$Setting, $SourceValue, $TargetValue, [string]$Status, [string]$DriftType)
		$rows.Add([PSCustomObject]@{
				Category    = $Category
				Setting     = $Setting
				SourceValue = $SourceValue
				TargetValue = $TargetValue
				Status      = $Status
				DriftType   = $DriftType
			})
	}

	function _Ignored
	{
		param ([string]$Name)
		foreach ($p in $ignore) { if ($Name -like $p) { return $true } }
		return $false
	}

	$sameMajor = ($Reference.Meta.MajorVersion -eq $Difference.Meta.MajorVersion)
	$refMap = @{ }
	foreach ($o in @($Reference.Options)) { $refMap[$o.Name.ToLowerInvariant()] = $o }
	$difMap = @{ }
	foreach ($o in @($Difference.Options)) { $difMap[$o.Name.ToLowerInvariant()] = $o }

	$allKeys = @($refMap.Keys) + @($difMap.Keys | Where-Object { -not $refMap.ContainsKey($_) }) | Sort-Object
	foreach ($key in $allKeys)
	{
		$r = $refMap[$key]
		$d = $difMap[$key]
		$name = if ($r) { $r.Name } else { $d.Name }
		if (_Ignored $name) { continue }

		if (-not $r -or -not $d)
		{
			if (-not $sameMajor) { continue }
			if (-not $r) { _Row 'ConfigOption' $name '<fehlt>' $d.ValueInUse 'Warning' 'missing' }
			else { _Row 'ConfigOption' $name $r.ValueInUse '<fehlt>' 'Warning' 'missing' }
			continue
		}

		if ($r.ValueInUse -ne $d.ValueInUse)
		{
			$status = if ($securityRelevant -contains $name) { 'Critical' } else { 'Warning' }
			_Row 'ConfigOption' $name $r.ValueInUse $d.ValueInUse $status 'value_in_use differs'
		}

		# Ausstehende Aenderung: konfigurierter Wert ungleich aktivem Wert (RECONFIGURE bzw. Neustart fehlt)
		$refPending = ($r.Value -ne $r.ValueInUse)
		$difPending = ($d.Value -ne $d.ValueInUse)
		# Nur melden, wenn sich der Pending-Zustand zwischen den Seiten unterscheidet: SQL Server zeigt z.B. bei
		# 'min server memory (MB)' dauerhaft konfiguriert 0 / aktiv 16 - das ist normal und kein Drift.
		if (($refPending -or $difPending) -and ($refPending -ne $difPending -or $r.Value -ne $d.Value))
		{
			$srcText = if ($refPending) { "$($r.ValueInUse) (konfiguriert $($r.Value))" } else { $r.ValueInUse }
			$tgtText = if ($difPending) { "$($d.ValueInUse) (konfiguriert $($d.Value))" } else { $d.ValueInUse }
			$dynamic = if ($difPending) { $d.IsDynamic } else { $r.IsDynamic }
			$kind = if ($dynamic) { 'pending (RECONFIGURE)' } else { 'pending (restart)' }
			_Row 'ConfigOption' "$name - ausstehend" $srcText $tgtText 'Warning' $kind
		}
	}

	if ($Reference.TraceFlagsRead -and $Difference.TraceFlagsRead)
	{
		$refFlags = @($Reference.TraceFlags)
		$difFlags = @($Difference.TraceFlags)
		foreach ($tf in ($refFlags + $difFlags | Sort-Object -Unique))
		{
			$inRef = $refFlags -contains $tf
			$inDif = $difFlags -contains $tf
			if ($inRef -and -not $inDif) { _Row 'TraceFlag' "Trace Flag $tf" 'aktiv' '<nicht aktiv>' 'Warning' 'trace flag' }
			elseif ($inDif -and -not $inRef) { _Row 'TraceFlag' "Trace Flag $tf" '<nicht aktiv>' 'aktiv' 'Warning' 'trace flag' }
		}
	}

	return $rows
}
