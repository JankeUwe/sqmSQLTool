<#
    Gemeinsame Hilfsfunktionen der Index-/Statistik-Wartung:
      Get-sqmStatisticsDecision - Entscheidung "Statistik aktualisieren?" (Invoke-sqmUpdateStatistics
                                  und Get-sqmStatisticsHealth nutzen dieselbe Regel)
      Get-sqmMaintEta           - geschaetzte Restlaufzeit aus bisherigem Fortschritt
#>

function Get-sqmStatisticsDecision
{
	[CmdletBinding()]
	param (
		[long]$Rows = 0,
		[object]$Modifications,
		[object]$AgeDays,
		[bool]$OnlyModified = $true,
		[ValidateSet('Dynamic', 'Any')]
		[string]$ModificationThreshold = 'Dynamic',
		[int]$ModificationPercent = 10,
		[int]$MaxAgeDays = 30
	)

	$mod = if ($null -eq $Modifications -or $Modifications -is [DBNull]) { $null } else { [long]$Modifications }
	$age = if ($null -eq $AgeDays -or $AgeDays -is [DBNull]) { $null } else { [int]$AgeDays }
	# Dynamische Schwelle: MIN(SQRT(1000 * Zeilen), Zeilen * Prozent / 100), mindestens 1
	$threshold = [long][math]::Max(1, [math]::Ceiling([math]::Min([math]::Sqrt(1000.0 * $Rows), $Rows * $ModificationPercent / 100.0)))

	$needs = $true
	$reason = 'All'
	if ($OnlyModified)
	{
		if ($null -eq $mod -or $mod -le 0)
		{
			$needs = $false
			$reason = 'NoChanges'
		}
		elseif ($ModificationThreshold -eq 'Any')
		{
			$reason = "Modified ($mod)"
		}
		elseif ($mod -ge $threshold)
		{
			$reason = "Threshold ($mod >= $threshold)"
		}
		elseif ($MaxAgeDays -gt 0 -and $null -ne $age -and $age -gt $MaxAgeDays)
		{
			$reason = "Age ($age d > $MaxAgeDays d, $mod changes)"
		}
		else
		{
			$needs = $false
			$reason = "BelowThreshold ($mod < $threshold)"
		}
	}
	[PSCustomObject]@{ Threshold = $threshold; NeedsUpdate = $needs; Reason = $reason }
}

function Get-sqmMaintEta
{
	[CmdletBinding()]
	[OutputType([string])]
	param (
		[Parameter(Mandatory = $true)]
		[timespan]$Elapsed,
		[Parameter(Mandatory = $true)]
		[double]$Done,
		[Parameter(Mandatory = $true)]
		[double]$Total
	)

	if ($Done -le 0 -or $Total -le $Done -or $Elapsed.TotalSeconds -lt 1) { return '' }
	$remaining = [timespan]::FromSeconds($Elapsed.TotalSeconds * ($Total - $Done) / $Done)
	'ETA ca. {0:00}:{1:00}:{2:00}' -f [math]::Floor($remaining.TotalHours), $remaining.Minutes, $remaining.Seconds
}

function Write-sqmMaintLine
{
	[CmdletBinding()]
	param ([Parameter(Mandatory = $true, Position = 0)][string]$Text)

	Write-Information -MessageData $Text -InformationAction Continue
}
