<#
.SYNOPSIS
    Returns disk information for a given drive letter.

.DESCRIPTION
    Accepts a drive letter, determines the associated disk number (disk number)
    and returns the total size, free space, percentage free and the serial number
    (LUN serial number) of the physical disk.

    The result is returned as a PSCustomObject and also copied to the clipboard
    as a formatted text table.

.PARAMETER DriveLetter
    Drive letter of the volume (e.g. "C", "C:" or "D:").

.PARAMETER NoClipboard
    Suppresses copying the result to the clipboard.

.EXAMPLE
    Get-sqmDiskInfoByDriveLetter -DriveLetter "C"

    Returns disk information for drive C: and copies it to the clipboard.

.EXAMPLE
    Get-sqmDiskInfoByDriveLetter "D:" -NoClipboard

    Returns disk information for drive D: without clipboard output.

.EXAMPLE
    "C","D","E" | ForEach-Object { Get-sqmDiskInfoByDriveLetter $_ }

    Returns disk information for multiple drives.

.OUTPUTS
    PSCustomObject with the following properties:
    - DriveLetter   : Drive letter (e.g. "C:")
    - DiskNumber    : Disk number (from Get-Disk)
    - TotalGB       : Total volume size in gigabytes
    - FreeGB        : Free disk space in gigabytes
    - FreePercent   : Percentage of free disk space
    - SerialNumber  : Serial number of the physical disk (LUN serial number)

.NOTES
    Author:       sqmSQLTool
    Prerequisites: Storage module (Get-Partition, Get-Disk), CIM (Win32_LogicalDisk)
    Clipboard:    Result is copied as formatted text table (unless -NoClipboard is used)
#>
function Get-sqmDiskInfoByDriveLetter
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
		[string]$DriveLetter,

		[Parameter(Mandatory = $false)]
		[switch]$NoClipboard
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$results      = [System.Collections.Generic.List[PSCustomObject]]::new()
	}

	process
	{
		# Normalize drive letter: remove colon, uppercase
		$Letter = $DriveLetter.TrimEnd(':').ToUpper()

		Invoke-sqmLogging -Message "[$Letter`:] Ermittle Disk-Informationen..." -FunctionName $functionName -Level "INFO"

		try
		{
			# 1. Partition for drive letter
			$partition  = Get-Partition -DriveLetter $Letter -ErrorAction Stop
			$diskNumber = $partition.DiskNumber

			# 2. Physical disk (serial number)
			$disk = Get-Disk -Number $diskNumber -ErrorAction Stop

			# 3. Volume information via CIM (free space, total)
			$logicalDisk = Get-CimInstance -ClassName Win32_LogicalDisk `
				-Filter "DeviceID='${Letter}:'" -ErrorAction Stop

			# Calculations
			$totalGB      = [math]::Round($logicalDisk.Size      / 1GB, 2)
			$freeGB       = [math]::Round($logicalDisk.FreeSpace / 1GB, 2)
			$freePercent  = if ($logicalDisk.Size -gt 0) {
				[math]::Round(($logicalDisk.FreeSpace / $logicalDisk.Size) * 100, 2)
			} else { 0 }

			$serialNumber = if ([string]::IsNullOrWhiteSpace($disk.SerialNumber)) {
				'N/A'
			} else {
				$disk.SerialNumber.Trim()
			}

			$result = [PSCustomObject]@{
				DriveLetter  = "${Letter}:"
				DiskNumber   = $diskNumber
				TotalGB      = $totalGB
				FreeGB       = $freeGB
				FreePercent  = $freePercent
				SerialNumber = $serialNumber
			}

			Invoke-sqmLogging -Message "[$Letter`:] DiskNr=$diskNumber  Total=${totalGB} GB  Free=${freeGB} GB (${freePercent}%)  SN=$serialNumber" -FunctionName $functionName -Level "INFO"

			$results.Add($result)
			$result
		}
		catch
		{
			Invoke-sqmLogging -Message "[$Letter`:] Fehler beim Abrufen der Disk-Informationen: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
			Write-Error "Fehler beim Abrufen der Informationen fuer Laufwerk ${Letter}: - $($_.Exception.Message)"
		}
	}

	end
	{
		if ($results.Count -eq 0 -or $NoClipboard) { return }

		# Format result as text table and copy to clipboard
		try
		{
			$clipText = $results | Format-Table -AutoSize | Out-String
			Set-Clipboard -Value $clipText.Trim()
			Invoke-sqmLogging -Message "Ergebnis ($($results.Count) Laufwerk(e)) in Zwischenablage kopiert." -FunctionName $functionName -Level "INFO"
		}
		catch
		{
			Invoke-sqmLogging -Message "Zwischenablage konnte nicht beschrieben werden: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
		}
	}
}
