<#
.SYNOPSIS
    Speichert alle Konfigurationsoptionen und globalen Trace Flags einer Instanz als Baseline (JSON).

.DESCRIPTION
    Liest die komplette sys.configurations (value, value_in_use, is_dynamic, is_advanced) und die globalen
    Trace Flags und schreibt sie mit Metadaten (Server, Version, Zeitpunkt, Label) in eine JSON-Datei.
    Mit Compare-sqmConfigBaseline laesst sich eine Instanz spaeter gegen diese Baseline pruefen
    (Config Drift) oder zwei Baselines gegeneinander vergleichen.

    Empfehlung: pro Hauptversion (z.B. SQL Server 2019 und 2022) eine eigene Baseline fuehren und jede
    Instanz nur gegen die Baseline ihrer Version pruefen. Die Hauptversion steht im Dateinamen.

.PARAMETER SqlInstance
    Instanz, deren Konfiguration gespeichert wird.

.PARAMETER SqlCredential
    Optionale SQL-Anmeldung.

.PARAMETER Label
    Optionale Bezeichnung, z.B. "Standard 2019" oder "nach Patchday". Wird in der JSON-Datei gespeichert.

.PARAMETER OutputPath
    Zielordner. Standard: <Ausgabepfad der Modulkonfiguration>\ConfigBaseline.

.PARAMETER EnableException
    Fehler werfen statt loggen und $null zurueckgeben.

.EXAMPLE
    Save-sqmConfigBaseline -SqlInstance "SQL01" -Label "Standard 2019"

.EXAMPLE
    $b = Save-sqmConfigBaseline -SqlInstance "SQL01" -OutputPath "D:\Baselines"
    Compare-sqmConfigBaseline -BaselinePath $b.BaselinePath -SqlInstance "SQL02"

.OUTPUTS
    [PSCustomObject] mit BaselinePath, SqlInstance, ServerName, ProductVersion, MajorVersion, OptionCount,
    TraceFlagCount, Label, CapturedAt.

.NOTES
    Uses Invoke-DbaQuery. Das Login braucht VIEW SERVER STATE (ab SQL Server 2022: VIEW SERVER PERFORMANCE STATE),
    sonst bleiben die Trace Flags leer und werden beim Vergleich uebersprungen.
#>
function Save-sqmConfigBaseline
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$Label,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'ConfigBaseline'),
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	try
	{
		if (-not (Get-Module -ListAvailable -Name dbatools)) { throw "dbatools-Modul nicht gefunden." }

		$set = Get-sqmConfigOptionSet -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Label $Label
		if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

		$safeName = ($set.Meta.ServerName -replace '[\\/:*?"<>|]', '_')
		$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
		$file = Join-Path $OutputPath "ConfigBaseline_${safeName}_v$($set.Meta.MajorVersion)_$stamp.json"

		$payload = [ordered]@{
			SchemaVersion  = 1
			Meta           = $set.Meta
			Options        = $set.Options
			TraceFlags     = @($set.TraceFlags)
			TraceFlagsRead = $set.TraceFlagsRead
		}
		[System.IO.File]::WriteAllText($file, ($payload | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($true)))

		Invoke-sqmLogging -Message "Baseline gespeichert: $file ($(@($set.Options).Count) Optionen, $(@($set.TraceFlags).Count) Trace Flags)" -FunctionName $functionName -Level "INFO"

		[PSCustomObject]@{
			BaselinePath   = $file
			SqlInstance    = $SqlInstance
			ServerName     = $set.Meta.ServerName
			ProductVersion = $set.Meta.ProductVersion
			MajorVersion   = $set.Meta.MajorVersion
			OptionCount    = @($set.Options).Count
			TraceFlagCount = @($set.TraceFlags).Count
			Label          = $Label
			CapturedAt     = $set.Meta.CapturedAt
		}
	}
	catch
	{
		Invoke-sqmLogging -Message "Baseline fuer '$SqlInstance' fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
		if ($EnableException) { throw }
		Write-Error "Baseline fuer '$SqlInstance' fehlgeschlagen: $($_.Exception.Message)"
		return $null
	}
}
