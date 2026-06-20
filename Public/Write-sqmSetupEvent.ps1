<#
.SYNOPSIS
    Appends a single structured setup event as one JSON line (JSON-Lines) to a file.

.DESCRIPTION
    Internal, side-effect-free helper for the optional animated setup replay report. Each call writes
    exactly one compact JSON object terminated by a newline, so the file is a JSON-Lines stream that
    New-sqmSetupReport replays as an animated HTML timeline.

    The whole body is wrapped in try/catch: a logging/serialization failure must NEVER affect the
    installation. When -Path is empty or $null the function is a no-op, so callers can invoke it
    unconditionally (the report is opt-in via the orchestrator's -ProgressReport switch).

.PARAMETER Path
    Target JSON-Lines file. Empty/$null -> no-op.

.PARAMETER Phase
    Coarse pipeline station (copy, preinstall, dirs, install, components, drivers, postinstall, alwayson).

.PARAMETER Step
    Stable step identifier within the phase (e.g. copy-sources, hadr, node-restart, listener).

.PARAMETER State
    start | progress | done | warn | error.

.PARAMETER Title
    Short human-readable label shown in the report.

.PARAMETER Detail
    Optional detail line (e.g. instance, path).

.PARAMETER Pct
    Optional progress percentage (0-100); -1 = not applicable.

.PARAMETER Node
    Optional node/instance the event relates to (for the AlwaysOn visuals).

.PARAMETER Viz
    Visualization hint for the front-end: flow-arrows | disk-format | gears | bar | node-restart |
    node-fetch | data-replicate | listener | check. Defaults to a sensible value per phase.
#>
function Write-sqmSetupEvent
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $false)]
		[string]$Path,

		[Parameter(Mandatory = $true)]
		[string]$Phase,

		[Parameter(Mandatory = $false)]
		[string]$Step = '',

		[Parameter(Mandatory = $false)]
		[ValidateSet('start', 'progress', 'done', 'warn', 'error')]
		[string]$State = 'progress',

		[Parameter(Mandatory = $false)]
		[string]$Title = '',

		[Parameter(Mandatory = $false)]
		[string]$Detail = '',

		[Parameter(Mandatory = $false)]
		[int]$Pct = -1,

		[Parameter(Mandatory = $false)]
		[string]$Node = '',

		[Parameter(Mandatory = $false)]
		[string]$Viz = ''
	)

	if ([string]::IsNullOrWhiteSpace($Path)) { return }

	try
	{
		# Default visualization per phase if not explicitly supplied
		if ([string]::IsNullOrWhiteSpace($Viz))
		{
			$Viz = switch ($Phase)
			{
				'copy'        { 'flow-arrows' }
				'preinstall'  { 'disk-format' }
				'dirs'        { 'bar' }
				'install'     { 'gears' }
				'components'  { 'gears' }
				'drivers'     { 'bar' }
				'postinstall' { 'gears' }
				'alwayson'    { 'data-replicate' }
				default       { 'bar' }
			}
		}

		$dir = Split-Path -Path $Path -Parent
		if ($dir -and -not (Test-Path -LiteralPath $dir)) {
			New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
		}

		$evt = [ordered]@{
			ts     = (Get-Date).ToString('o')
			phase  = $Phase
			step   = $Step
			state  = $State
			title  = $Title
			detail = $Detail
			pct    = $Pct
			node   = $Node
			viz    = $Viz
		}

		$json = ($evt | ConvertTo-Json -Compress -Depth 4)
		# One object per line; ConvertTo-Json -Compress never emits newlines, so this stays valid JSON-Lines.
		Add-Content -LiteralPath $Path -Value $json -Encoding UTF8 -ErrorAction Stop
	}
	catch
	{
		# Never let report instrumentation break the setup.
		Write-Verbose "Write-sqmSetupEvent: $($_.Exception.Message)"
	}
}
