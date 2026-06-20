<#
.SYNOPSIS
    Sets MAXDOP (max degree of parallelism) to the recommended (or an explicit) value,
    and optionally the matching "cost threshold for parallelism".

.DESCRIPTION
    Companion to Test-sqmMaxDop: instead of only reporting, this applies the value.
    By default MAXDOP is set to the Microsoft recommendation min(8, logical CPUs); pass
    -MaxDop to set an exact value. The recommended "cost threshold for parallelism" (50)
    is set alongside unless -SkipCostThreshold is used. Uses dbatools and is fully
    ShouldProcess-aware (-WhatIf / -Confirm).

.PARAMETER SqlInstance
    SQL Server instance (default: $env:COMPUTERNAME).

.PARAMETER SqlCredential
    Optional SQL authentication credential (PSCredential).

.PARAMETER MaxDop
    Explicit MAXDOP value. When omitted, min(8, logical CPUs) is used.

.PARAMETER CostThreshold
    Value for "cost threshold for parallelism". Default: 50. Ignored with -SkipCostThreshold.

.PARAMETER SkipCostThreshold
    Do not change the cost threshold; only set MAXDOP.

.PARAMETER EnableException
    Throw on error instead of logging a warning and returning a failed result.

.OUTPUTS
    [PSCustomObject] with SqlInstance, PreviousMaxDop, NewMaxDop, LogicalCPUs,
    PreviousCostThreshold, NewCostThreshold, Status, Message.

.EXAMPLE
    Set-sqmMaxDop -SqlInstance SQL01
    Sets MAXDOP to min(8, CPUs) and cost threshold to 50.

.EXAMPLE
    Set-sqmMaxDop -SqlInstance SQL01 -MaxDop 4 -SkipCostThreshold
    Sets MAXDOP to 4, leaves the cost threshold unchanged.

.EXAMPLE
    Set-sqmMaxDop -SqlInstance SQL01 -WhatIf
    Shows the planned MAXDOP/cost-threshold change without applying it.

.NOTES
    Requires dbatools and sysadmin on the instance. Pairs with Test-sqmMaxDop (read-only check).
#>
function Set-sqmMaxDop
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 32767)]
		[int]$MaxDop,

		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 32767)]
		[int]$CostThreshold = 50,

		[Parameter(Mandatory = $false)]
		[switch]$SkipCostThreshold,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name

	$result = [PSCustomObject]@{
		SqlInstance           = $SqlInstance
		PreviousMaxDop        = $null
		NewMaxDop             = $null
		LogicalCPUs           = $null
		PreviousCostThreshold = $null
		NewCostThreshold      = $null
		Status                = 'Error'
		Message               = $null
	}

	function _Log { param([string]$Msg, [string]$Level = 'INFO')
		Write-Verbose "[$functionName] $Msg"
		try { Invoke-sqmLogging -Message $Msg -FunctionName $functionName -Level $Level } catch { }
	}

	try
	{
		if (-not (Get-Module -ListAvailable -Name dbatools))
		{
			throw "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
		}

		$connArgs = @{ SqlInstance = $SqlInstance; ErrorAction = 'Stop' }
		if ($SqlCredential) { $connArgs['SqlCredential'] = $SqlCredential }

		# Empfehlung bestimmen
		$cpuCount = (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop).NumberOfLogicalProcessors
		$result.LogicalCPUs = $cpuCount
		$targetDop = if ($PSBoundParameters.ContainsKey('MaxDop')) { $MaxDop } else { [math]::Min(8, $cpuCount) }
		$result.NewMaxDop = $targetDop

		# Aktuelle Werte lesen
		$curDop = Get-DbaSpConfigure @connArgs -Name 'max degree of parallelism'
		$result.PreviousMaxDop = [int]$curDop.RunningValue
		if (-not $SkipCostThreshold)
		{
			$curCost = Get-DbaSpConfigure @connArgs -Name 'cost threshold for parallelism'
			$result.PreviousCostThreshold = [int]$curCost.RunningValue
			$result.NewCostThreshold      = $CostThreshold
		}

		$planMsg = "MAXDOP $($result.PreviousMaxDop) -> $targetDop" +
			$(if (-not $SkipCostThreshold) { "; Cost Threshold $($result.PreviousCostThreshold) -> $CostThreshold" } else { '' })
		_Log "Logische CPUs: $cpuCount | $planMsg"

		if (-not $PSCmdlet.ShouldProcess($SqlInstance, $planMsg))
		{
			$result.Status  = 'WhatIf'
			$result.Message = "Wuerde setzen: $planMsg"
			_Log $result.Message 'INFO'
			return $result
		}

		$null = Set-DbaSpConfigure @connArgs -Name 'max degree of parallelism' -Value $targetDop
		if (-not $SkipCostThreshold)
		{
			$null = Set-DbaSpConfigure @connArgs -Name 'cost threshold for parallelism' -Value $CostThreshold
		}

		$result.Status  = 'Success'
		$result.Message = "Gesetzt: $planMsg"
		_Log $result.Message 'INFO'
	}
	catch
	{
		$result.Status  = 'Error'
		$result.Message = "Fehler beim Setzen von MAXDOP: $($_.Exception.Message)"
		_Log $result.Message 'ERROR'
		if ($EnableException) { throw }
		Write-Error $result.Message
	}

	return $result
}
