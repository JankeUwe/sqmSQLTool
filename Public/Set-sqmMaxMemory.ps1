<#
.SYNOPSIS
    Sets SQL Server "max server memory (MB)" to the recommended (or an explicit) value.

.DESCRIPTION
    Companion to Test-sqmMaxMemory: instead of only reporting, this applies the value.
    By default it sets max server memory to a percentage of physical RAM (90% by default);
    pass -MaxMemoryMB to set an exact value. Uses dbatools (Set-DbaMaxMemory) and is fully
    ShouldProcess-aware (-WhatIf / -Confirm).

.PARAMETER SqlInstance
    SQL Server instance (default: $env:COMPUTERNAME).

.PARAMETER SqlCredential
    Optional SQL authentication credential (PSCredential).

.PARAMETER RecommendedPct
    Percentage of physical RAM to assign when -MaxMemoryMB is not given. Default: 90.

.PARAMETER MaxMemoryMB
    Explicit value in MB. Overrides -RecommendedPct and -InstanceCount (an explicit value is
    assumed to already account for any other instances on the host).

.PARAMETER InstanceCount
    Number of SQL Server Engine instances sharing this host's RAM, used to split the
    -RecommendedPct budget between them. Auto-detected by default (see
    Get-sqmHostEngineInstanceCount); pass this to override when auto-detection isn't reliable
    (e.g. remote host with WinRM blocked) or a future instance isn't installed yet.

.PARAMETER EnableException
    Throw on error instead of logging a warning and returning a failed result.

.OUTPUTS
    [PSCustomObject] with SqlInstance, PreviousMaxMemMB, NewMaxMemMB, TotalRamMB, InstanceCount,
    Status, Message.

.EXAMPLE
    Set-sqmMaxMemory -SqlInstance SQL01
    Sets max server memory to 90% of physical RAM.

.EXAMPLE
    Set-sqmMaxMemory -SqlInstance SQL01 -MaxMemoryMB 24576
    Sets max server memory to exactly 24 GB.

.EXAMPLE
    Set-sqmMaxMemory -SqlInstance SQL01 -RecommendedPct 80 -WhatIf
    Shows what would be set (80% of RAM) without changing anything.

.NOTES
    Requires dbatools and sysadmin on the instance. Pairs with Test-sqmMaxMemory (read-only check).
#>
function Set-sqmMaxMemory
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[ValidateRange(70, 99)]
		[int]$RecommendedPct = 90,

		[Parameter(Mandatory = $false)]
		[ValidateRange(512, [int]::MaxValue)]
		[int]$MaxMemoryMB,

		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 64)]
		[int]$InstanceCount,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name

	$result = [PSCustomObject]@{
		SqlInstance      = $SqlInstance
		PreviousMaxMemMB = $null
		NewMaxMemMB      = $null
		TotalRamMB       = $null
		InstanceCount    = $null
		Status           = 'Error'
		Message          = $null
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

		# Aktuellen Wert lesen
		$current = Get-DbaMaxMemory @connArgs
		$result.PreviousMaxMemMB = [int]$current.MaxValue
		$result.TotalRamMB       = [int]$current.Total

		# Zielwert bestimmen
		if ($PSBoundParameters.ContainsKey('MaxMemoryMB'))
		{
			$targetMB = $MaxMemoryMB
		}
		else
		{
			$totalRamMB = [int]$current.Total
			if (-not $totalRamMB -or $totalRamMB -le 0)
			{
				$totalRamMB = [math]::Round((Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1MB)
				$result.TotalRamMB = $totalRamMB
			}

			# RecommendedPct of TOTAL RAM is only correct for a single instance - on a host
			# running several Engine instances side by side, applying that same percentage to
			# EACH one massively over-commits RAM (e.g. two instances both at 90% = 180% total).
			# Split the RAM budget across however many Engine instances actually share this host,
			# unless the caller already knows the number (-InstanceCount).
			$instCount = if ($PSBoundParameters.ContainsKey('InstanceCount')) { $InstanceCount }
			else { Get-sqmHostEngineInstanceCount -SqlInstance $SqlInstance }
			$result.InstanceCount = $instCount
			$targetMB = [math]::Round(($totalRamMB * ($RecommendedPct / 100)) / $instCount)
			if ($instCount -gt 1)
			{
				_Log "Host hat $instCount Engine-Instanzen - RAM-Budget wird geteilt ($targetMB MB je Instanz)."
			}
		}
		$result.NewMaxMemMB = $targetMB

		_Log "Aktuell: $($result.PreviousMaxMemMB) MB | Ziel: $targetMB MB | RAM: $($result.TotalRamMB) MB"

		if (-not $PSCmdlet.ShouldProcess($SqlInstance, "max server memory auf $targetMB MB setzen (vorher $($result.PreviousMaxMemMB) MB)"))
		{
			$result.Status  = 'WhatIf'
			$result.Message = "Wuerde max server memory auf $targetMB MB setzen (aktuell $($result.PreviousMaxMemMB) MB)."
			_Log $result.Message 'INFO'
			return $result
		}

		$applied = Set-DbaMaxMemory @connArgs -Max $targetMB
		$result.NewMaxMemMB = [int]$applied.MaxValue
		$result.Status  = 'Success'
		$result.Message = "max server memory auf $($result.NewMaxMemMB) MB gesetzt (vorher $($result.PreviousMaxMemMB) MB)."
		_Log $result.Message 'INFO'
	}
	catch
	{
		$result.Status  = 'Error'
		$result.Message = "Fehler beim Setzen von max server memory: $($_.Exception.Message)"
		_Log $result.Message 'ERROR'
		if ($EnableException) { throw }
		Write-Error $result.Message
	}

	return $result
}
