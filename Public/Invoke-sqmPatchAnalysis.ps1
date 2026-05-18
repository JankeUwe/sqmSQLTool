<#
.SYNOPSIS
    Compares the installed SQL Server version with known CU/SP builds.

.DESCRIPTION
    Reads the installed SQL Server version (ProductVersion) and compares it
    against an embedded reference table of known builds. Indicates whether the
    instance is current, how many builds it lags behind the latest, and provides
    a patch recommendation.

.PARAMETER SqlInstance
    One or more SQL Server instances. Default: local computer name.
    Pipeline-capable.

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER OutputPath
    If specified, a CSV report is saved.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Invoke-sqmPatchAnalysis -SqlInstance "SQL01"

.EXAMPLE
    "SQL01","SQL02","SQL03" | Invoke-sqmPatchAnalysis

.EXAMPLE
    Invoke-sqmPatchAnalysis -SqlInstance "SQL01","SQL02" -OutputPath "D:\Reports"

.NOTES
    The embedded reference table contains known builds at the time the module was created.
    Newer CUs are not loaded automatically.
    Reference: https://sqlserverbuilds.blogspot.com/
#>
function Invoke-sqmPatchAnalysis
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[string[]]$SqlInstance = @($env:COMPUTERNAME),
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = _s 'Error_dbatoolsNotFound'
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		# ============================================================
		# Eingebettete Build-Referenztabelle
		# Format: MajorVersion -> geordnete Liste von [BuildNumber, Label, ReleaseDate]
		# ============================================================
		$buildReference = @{
			13 = @(  # SQL Server 2016
				[PSCustomObject]@{ Build = [version]'13.0.1601.5'; Label = 'RTM';         ReleaseDate = '2016-06-01' }
				[PSCustomObject]@{ Build = [version]'13.0.4001.0'; Label = 'SP1';         ReleaseDate = '2016-11-16' }
				[PSCustomObject]@{ Build = [version]'13.0.4422.0'; Label = 'SP1 CU4';     ReleaseDate = '2017-05-15' }
				[PSCustomObject]@{ Build = [version]'13.0.4528.0'; Label = 'SP1 CU7';     ReleaseDate = '2017-11-22' }
				[PSCustomObject]@{ Build = [version]'13.0.5026.0'; Label = 'SP2';         ReleaseDate = '2018-04-24' }
				[PSCustomObject]@{ Build = [version]'13.0.5201.2'; Label = 'SP2 CU1';     ReleaseDate = '2018-05-30' }
				[PSCustomObject]@{ Build = [version]'13.0.5337.0'; Label = 'SP2 CU5';     ReleaseDate = '2018-09-18' }
				[PSCustomObject]@{ Build = [version]'13.0.5492.2'; Label = 'SP2 CU8';     ReleaseDate = '2019-03-19' }
				[PSCustomObject]@{ Build = [version]'13.0.5598.27';Label = 'SP2 CU13';    ReleaseDate = '2019-09-26' }
				[PSCustomObject]@{ Build = [version]'13.0.5830.85';Label = 'SP2 CU17';    ReleaseDate = '2020-11-20' }
				[PSCustomObject]@{ Build = [version]'13.0.6300.2'; Label = 'SP3';         ReleaseDate = '2021-09-15' }
				[PSCustomObject]@{ Build = [version]'13.0.6404.1'; Label = 'SP3 CU1';     ReleaseDate = '2021-10-18' }
				[PSCustomObject]@{ Build = [version]'13.0.6419.1'; Label = 'SP3 CU2';     ReleaseDate = '2022-01-19' }
				[PSCustomObject]@{ Build = [version]'13.0.6430.49';Label = 'SP3 CU3';     ReleaseDate = '2022-03-16' }
				[PSCustomObject]@{ Build = [version]'13.0.6435.1'; Label = 'SP3 CU4 (latest)'; ReleaseDate = '2022-09-22' }
			)
			14 = @(  # SQL Server 2017
				[PSCustomObject]@{ Build = [version]'14.0.1000.169'; Label = 'RTM';        ReleaseDate = '2017-10-02' }
				[PSCustomObject]@{ Build = [version]'14.0.3006.16';  Label = 'CU1';        ReleaseDate = '2017-10-24' }
				[PSCustomObject]@{ Build = [version]'14.0.3030.27';  Label = 'CU4';        ReleaseDate = '2018-02-20' }
				[PSCustomObject]@{ Build = [version]'14.0.3048.4';   Label = 'CU6';        ReleaseDate = '2018-04-17' }
				[PSCustomObject]@{ Build = [version]'14.0.3076.1';   Label = 'CU8';        ReleaseDate = '2018-06-21' }
				[PSCustomObject]@{ Build = [version]'14.0.3162.1';   Label = 'CU12';       ReleaseDate = '2018-10-25' }
				[PSCustomObject]@{ Build = [version]'14.0.3192.2';   Label = 'CU14';       ReleaseDate = '2019-03-25' }
				[PSCustomObject]@{ Build = [version]'14.0.3238.1';   Label = 'CU17';       ReleaseDate = '2019-10-08' }
				[PSCustomObject]@{ Build = [version]'14.0.3294.2';   Label = 'CU20';       ReleaseDate = '2020-04-07' }
				[PSCustomObject]@{ Build = [version]'14.0.3335.7';   Label = 'CU22';       ReleaseDate = '2020-09-10' }
				[PSCustomObject]@{ Build = [version]'14.0.3381.3';   Label = 'CU26';       ReleaseDate = '2021-09-14' }
				[PSCustomObject]@{ Build = [version]'14.0.3421.10';  Label = 'CU29';       ReleaseDate = '2022-03-30' }
				[PSCustomObject]@{ Build = [version]'14.0.3436.1';   Label = 'CU31';       ReleaseDate = '2022-09-20' }
				[PSCustomObject]@{ Build = [version]'14.0.3460.9';   Label = 'CU39';       ReleaseDate = '2023-11-14' }
				[PSCustomObject]@{ Build = [version]'14.0.3465.1';   Label = 'CU40 (latest)'; ReleaseDate = '2024-04-11' }
			)
			15 = @(  # SQL Server 2019
				[PSCustomObject]@{ Build = [version]'15.0.2000.5';   Label = 'RTM';        ReleaseDate = '2019-11-04' }
				[PSCustomObject]@{ Build = [version]'15.0.4003.23';  Label = 'CU1';        ReleaseDate = '2020-01-07' }
				[PSCustomObject]@{ Build = [version]'15.0.4013.40';  Label = 'CU2';        ReleaseDate = '2020-02-13' }
				[PSCustomObject]@{ Build = [version]'15.0.4023.6';   Label = 'CU3';        ReleaseDate = '2020-03-12' }
				[PSCustomObject]@{ Build = [version]'15.0.4033.1';   Label = 'CU4';        ReleaseDate = '2020-03-31' }
				[PSCustomObject]@{ Build = [version]'15.0.4043.16';  Label = 'CU5';        ReleaseDate = '2020-06-22' }
				[PSCustomObject]@{ Build = [version]'15.0.4053.23';  Label = 'CU6';        ReleaseDate = '2020-08-04' }
				[PSCustomObject]@{ Build = [version]'15.0.4063.15';  Label = 'CU7';        ReleaseDate = '2020-09-02' }
				[PSCustomObject]@{ Build = [version]'15.0.4073.23';  Label = 'CU8';        ReleaseDate = '2020-10-01' }
				[PSCustomObject]@{ Build = [version]'15.0.4102.2';   Label = 'CU10';       ReleaseDate = '2021-06-08' }
				[PSCustomObject]@{ Build = [version]'15.0.4153.1';   Label = 'CU14';       ReleaseDate = '2021-11-22' }
				[PSCustomObject]@{ Build = [version]'15.0.4198.2';   Label = 'CU16';       ReleaseDate = '2022-04-18' }
				[PSCustomObject]@{ Build = [version]'15.0.4236.7';   Label = 'CU18';       ReleaseDate = '2022-09-28' }
				[PSCustomObject]@{ Build = [version]'15.0.4298.1';   Label = 'CU22';       ReleaseDate = '2023-08-14' }
				[PSCustomObject]@{ Build = [version]'15.0.4335.1';   Label = 'CU25';       ReleaseDate = '2024-02-15' }
				[PSCustomObject]@{ Build = [version]'15.0.4385.2';   Label = 'CU29 (latest)'; ReleaseDate = '2024-12-12' }
			)
			16 = @(  # SQL Server 2022
				[PSCustomObject]@{ Build = [version]'16.0.1000.6';   Label = 'RTM';        ReleaseDate = '2022-11-16' }
				[PSCustomObject]@{ Build = [version]'16.0.4003.1';   Label = 'CU1';        ReleaseDate = '2023-02-16' }
				[PSCustomObject]@{ Build = [version]'16.0.4015.1';   Label = 'CU2';        ReleaseDate = '2023-03-15' }
				[PSCustomObject]@{ Build = [version]'16.0.4025.1';   Label = 'CU3';        ReleaseDate = '2023-04-13' }
				[PSCustomObject]@{ Build = [version]'16.0.4035.4';   Label = 'CU4';        ReleaseDate = '2023-05-11' }
				[PSCustomObject]@{ Build = [version]'16.0.4045.3';   Label = 'CU5';        ReleaseDate = '2023-06-15' }
				[PSCustomObject]@{ Build = [version]'16.0.4055.4';   Label = 'CU6';        ReleaseDate = '2023-07-13' }
				[PSCustomObject]@{ Build = [version]'16.0.4065.3';   Label = 'CU7';        ReleaseDate = '2023-08-10' }
				[PSCustomObject]@{ Build = [version]'16.0.4075.1';   Label = 'CU8';        ReleaseDate = '2023-09-14' }
				[PSCustomObject]@{ Build = [version]'16.0.4085.2';   Label = 'CU9';        ReleaseDate = '2023-10-12' }
				[PSCustomObject]@{ Build = [version]'16.0.4095.4';   Label = 'CU10';       ReleaseDate = '2023-11-16' }
				[PSCustomObject]@{ Build = [version]'16.0.4105.2';   Label = 'CU11';       ReleaseDate = '2024-01-11' }
				[PSCustomObject]@{ Build = [version]'16.0.4115.5';   Label = 'CU12';       ReleaseDate = '2024-03-14' }
				[PSCustomObject]@{ Build = [version]'16.0.4125.3';   Label = 'CU13';       ReleaseDate = '2024-05-16' }
				[PSCustomObject]@{ Build = [version]'16.0.4135.4';   Label = 'CU14';       ReleaseDate = '2024-07-11' }
				[PSCustomObject]@{ Build = [version]'16.0.4145.4';   Label = 'CU15';       ReleaseDate = '2024-09-12' }
				[PSCustomObject]@{ Build = [version]'16.0.4155.4';   Label = 'CU16';       ReleaseDate = '2024-11-14' }
				[PSCustomObject]@{ Build = [version]'16.0.4165.4';   Label = 'CU17 (latest)'; ReleaseDate = '2025-01-16' }
			)
		}

		$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
		Invoke-sqmLogging -Message (_s 'PatchAnalysis_Starting' $functionName, $SqlInstance.Count) -FunctionName $functionName -Level "INFO"
	}

	process
	{
		foreach ($inst in $SqlInstance)
		{
			try
			{
				$connParams = @{ SqlInstance = $inst }
				if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

				$versionSql = @"
SELECT
    CAST(SERVERPROPERTY('ProductVersion')       AS NVARCHAR(50)) AS ProductVersion,
    CAST(SERVERPROPERTY('ProductLevel')         AS NVARCHAR(50)) AS ProductLevel,
    CAST(SERVERPROPERTY('ProductUpdateLevel')   AS NVARCHAR(50)) AS ProductUpdateLevel,
    CAST(SERVERPROPERTY('Edition')              AS NVARCHAR(100)) AS Edition,
    CAST(SERVERPROPERTY('EngineEdition')        AS INT)          AS EngineEdition,
    @@VERSION                                                     AS FullVersion
"@
				$vRow = Invoke-DbaQuery @connParams -Database master -Query $versionSql -ErrorAction Stop

				$installed = [version]$vRow.ProductVersion
				$major     = $installed.Major

				$sqlYear = switch ($major)
				{
					13 { 'SQL Server 2016' }
					14 { 'SQL Server 2017' }
					15 { 'SQL Server 2019' }
					16 { 'SQL Server 2022' }
					default { "SQL Server (Major $major)" }
				}

				# Builds fuer diese Version
				$builds = $buildReference[$major]

				if (-not $builds)
				{
					$allResults.Add([PSCustomObject]@{
						SqlInstance       = $inst
						ProductVersion    = $vRow.ProductVersion
						ProductLevel      = $vRow.ProductLevel
						Edition           = $vRow.Edition
						MajorVersion      = $sqlYear
						LatestKnownBuild  = 'N/A'
						LatestKnownLabel  = 'N/A'
						IsLatest          = $null
						BuildsBehind      = $null
						PatchStatus       = 'Unknown'
						Recommendation    = _s 'PatchRec_UnknownVersion' $major
					})
					continue
				}

				$latestBuild = $builds[-1]
				$isLatest    = ($installed -ge $latestBuild.Build)

				# Wie viele bekannte Builds ist die Instanz hinter dem neuesten Stand?
				$buildsBehind = 0
				for ($i = 0; $i -lt $builds.Count; $i++)
				{
					if ($installed -lt $builds[$i].Build) { $buildsBehind = $builds.Count - $i; break }
				}

				# Naechsthoeheren bekannten Build bestimmen
				$nextBuild = $builds | Where-Object { $_.Build -gt $installed } | Select-Object -First 1

				$patchStatus = if ($isLatest) { 'UpToDate' }
				elseif ($buildsBehind -ge 5)  { 'Critical' }
				elseif ($buildsBehind -ge 3)  { 'MajorUpdate' }
				else                           { 'MinorUpdate' }

				$nextLabel = if ($nextBuild) { $nextBuild.Label } else { $latestBuild.Label }
				$recommendation = if ($isLatest) { _s 'PatchRec_UpToDate' }
				else { _s 'PatchRec_Outdated' $buildsBehind, $nextLabel, $latestBuild.Label, $latestBuild.Build }

				Invoke-sqmLogging -Message (_s 'PatchAnalysis_InstanceResult' $inst, $sqlYear, $vRow.ProductVersion, $patchStatus, $buildsBehind) -FunctionName $functionName -Level "INFO"

				$allResults.Add([PSCustomObject]@{
					SqlInstance       = $inst
					ProductVersion    = $vRow.ProductVersion
					ProductLevel      = $vRow.ProductLevel
					UpdateLevel       = $vRow.ProductUpdateLevel
					Edition           = $vRow.Edition
					MajorVersion      = $sqlYear
					InstalledBuild    = $installed.ToString()
					LatestKnownBuild  = $latestBuild.Build.ToString()
					LatestKnownLabel  = $latestBuild.Label
					LatestReleaseDate = $latestBuild.ReleaseDate
					IsLatest          = $isLatest
					BuildsBehind      = $buildsBehind
					PatchStatus       = $patchStatus
					Recommendation    = $recommendation
				})
			}
			catch
			{
				$errMsg = _s 'PatchAnalysis_InstanceError' $inst, $_.Exception.Message
				Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
				$allResults.Add([PSCustomObject]@{
					SqlInstance    = $inst
					PatchStatus    = 'Error'
					Recommendation = $errMsg
				})
				if ($EnableException) { throw }
			}
		}
	}

	end
	{
		if ($OutputPath -and $allResults.Count -gt 0)
		{
			if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
			$ts      = Get-Date -Format 'yyyyMMdd_HHmsqm'
			$csvFile = Join-Path $OutputPath "PatchAnalysis_${ts}.csv"
			$allResults | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
			Invoke-sqmLogging -Message (_s 'PatchAnalysis_Saved' $csvFile) -FunctionName $functionName -Level "INFO"
		}

		$critical = @($allResults | Where-Object { $_.PatchStatus -eq 'Critical' }).Count
		$outdated  = @($allResults | Where-Object { $_.PatchStatus -in @('MajorUpdate','MinorUpdate') }).Count
		Invoke-sqmLogging -Message (_s 'PatchAnalysis_Completed' $functionName, $allResults.Count, $critical, $outdated) -FunctionName $functionName -Level "INFO"

		return $allResults.ToArray()
	}
}
