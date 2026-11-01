#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Config-Drift: Get-sqmConfigOptionSet, Compare-sqmConfigOptionSet (privat),
    Save-sqmConfigBaseline, Compare-sqmConfigBaseline und Compare-sqmServerConfiguration -AllConfigOptions.
    Die Zeilenlogik (value_in_use, ausstehend, Version-only, Trace Flags) ist zusaetzlich live gegen
    SQL Server 2022 (DEV01) geprueft.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
	$script:TestDir = New-TempTestDirectory

	function global:New-CfgSet
	{
		param ([int]$Major = 16, [hashtable]$Opt = @{ }, [int[]]$Flags = @(), [bool]$FlagsRead = $true)
		$base = [ordered]@{ 'max degree of parallelism' = @(0, 0, $true, $false); 'xp_cmdshell' = @(0, 0, $true, $true); 'user connections' = @(0, 0, $false, $true) }
		foreach ($k in $Opt.Keys) { $base[$k] = $Opt[$k] }
		$i = 0
		[PSCustomObject]@{
			Meta           = [PSCustomObject]@{ ServerName = 'T1'; ProductVersion = "$Major.0.1"; MajorVersion = $Major; CapturedAt = '2026-11-01T10:00:00' }
			Options        = @($base.Keys | ForEach-Object { $i++; [PSCustomObject]@{ ConfigurationId = $i; Name = $_; Value = [int64]$base[$_][0]; ValueInUse = [int64]$base[$_][1]; IsDynamic = [bool]$base[$_][2]; IsAdvanced = [bool]$base[$_][3] } })
			TraceFlags     = $Flags
			TraceFlagsRead = $FlagsRead
		}
	}
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
	Remove-Item function:\New-CfgSet -ErrorAction SilentlyContinue
	$env:SQMSQLTOOL_SKIP_AUTO_UPDATE = $null
}

Describe 'Compare-sqmConfigOptionSet' {
	It 'liefert bei identischen Staenden keine Zeilen' {
		InModuleScope sqmSQLTool {
			@(Compare-sqmConfigOptionSet -Reference (New-CfgSet) -Difference (New-CfgSet)).Count | Should -Be 0
		}
	}

	It 'meldet abweichendes value_in_use als Warning, sicherheitsrelevantes (xp_cmdshell) als Critical' {
		InModuleScope sqmSQLTool {
			$r = @(Compare-sqmConfigOptionSet -Reference (New-CfgSet) -Difference (New-CfgSet -Opt @{ 'max degree of parallelism' = @(8, 8, $true, $false); 'xp_cmdshell' = @(1, 1, $true, $true) }))
			$dop = $r | Where-Object Setting -eq 'max degree of parallelism'
			$dop.Status | Should -Be 'Warning'
			$dop.SourceValue | Should -Be 0
			$dop.TargetValue | Should -Be 8
			($r | Where-Object Setting -eq 'xp_cmdshell').Status | Should -Be 'Critical'
		}
	}

	It 'erkennt ausstehende Aenderung: dynamisch = RECONFIGURE, nicht dynamisch = restart' {
		InModuleScope sqmSQLTool {
			$r = @(Compare-sqmConfigOptionSet -Reference (New-CfgSet) -Difference (New-CfgSet -Opt @{ 'max degree of parallelism' = @(8, 0, $true, $false); 'user connections' = @(100, 0, $false, $true) }))
			($r | Where-Object Setting -eq 'max degree of parallelism - ausstehend').DriftType | Should -Be 'pending (RECONFIGURE)'
			($r | Where-Object Setting -eq 'user connections - ausstehend').DriftType | Should -Be 'pending (restart)'
		}
	}

	It 'meldet keinen Drift, wenn beide Seiten identisch ausstehend sind (min server memory 0/16)' {
		InModuleScope sqmSQLTool {
			$o = @{ 'min server memory (MB)' = @(0, 16, $true, $false) }
			@(Compare-sqmConfigOptionSet -Reference (New-CfgSet -Opt $o) -Difference (New-CfgSet -Opt $o)).Count | Should -Be 0
		}
	}

	It 'ueberspringt Optionen, die nur in einer Hauptversion existieren, meldet sie aber bei gleicher Version als missing' {
		InModuleScope sqmSQLTool {
			$extra = @{ 'neue option' = @(1, 1, $true, $true) }
			@(Compare-sqmConfigOptionSet -Reference (New-CfgSet -Major 16) -Difference (New-CfgSet -Major 17 -Opt $extra)).Count | Should -Be 0
			$r = @(Compare-sqmConfigOptionSet -Reference (New-CfgSet -Major 16) -Difference (New-CfgSet -Major 16 -Opt $extra))
			$r.Count | Should -Be 1
			$r[0].DriftType | Should -Be 'missing'
			$r[0].SourceValue | Should -Be '<fehlt>'
		}
	}

	It 'ignoriert version high/low part, show advanced options und -IgnoreOption' {
		InModuleScope sqmSQLTool {
			$a = New-CfgSet -Opt @{ 'version high part of SQL Server' = @(0, 0, $true, $true); 'show advanced options' = @(0, 0, $true, $false) }
			$b = New-CfgSet -Opt @{ 'version high part of SQL Server' = @(9, 9, $true, $true); 'show advanced options' = @(1, 1, $true, $false); 'user connections' = @(50, 50, $false, $true) }
			@(Compare-sqmConfigOptionSet -Reference $a -Difference $b -IgnoreOption 'user conn*').Count | Should -Be 0
			@(Compare-sqmConfigOptionSet -Reference $a -Difference $b).Count | Should -Be 1
		}
	}

	It 'meldet Trace Flags nur auf einer Seite, und nur wenn beide Seiten lesbar waren' {
		InModuleScope sqmSQLTool {
			$r = @(Compare-sqmConfigOptionSet -Reference (New-CfgSet -Flags @(1118, 3226)) -Difference (New-CfgSet -Flags @(3226, 4199)))
			($r | Where-Object Setting -eq 'Trace Flag 1118').TargetValue | Should -Be '<nicht aktiv>'
			($r | Where-Object Setting -eq 'Trace Flag 4199').SourceValue | Should -Be '<nicht aktiv>'
			($r | Where-Object Setting -eq 'Trace Flag 3226') | Should -BeNullOrEmpty
			@(Compare-sqmConfigOptionSet -Reference (New-CfgSet -Flags @(1118)) -Difference (New-CfgSet -FlagsRead $false)).Count | Should -Be 0
		}
	}
}

Describe 'Get-sqmConfigOptionSet' {
	It 'liest Optionen, Meta und globale Trace Flags; Trace-Flag-Fehler setzt TraceFlagsRead auf false' {
		InModuleScope sqmSQLTool {
			Mock Invoke-DbaQuery {
				if (-not $EnableException) { return }
				if ($Query -match 'sys\.configurations') { return @([PSCustomObject]@{ ConfigurationId = 1520; Name = 'xp_cmdshell'; Value = 1; ValueInUse = 0; IsDynamic = 1; IsAdvanced = 1 }) }
				if ($Query -match 'SERVERPROPERTY') { return [PSCustomObject]@{ ServerName = 'SRV'; ProductVersion = '16.0.4100.1'; Edition = 'Developer' } }
				if ($script:failFlags) { throw 'no permission' }
				@([PSCustomObject]@{ TraceFlag = 3226; Status = 1; Global = 1; Session = 0 }, [PSCustomObject]@{ TraceFlag = 9999; Status = 1; Global = 0; Session = 1 })
			}
			$script:failFlags = $false
			$s = Get-sqmConfigOptionSet -SqlInstance 'SRV'
			$s.Meta.MajorVersion | Should -Be 16
			$s.Options[0].Value | Should -Be 1
			$s.Options[0].ValueInUse | Should -Be 0
			$s.Options[0].IsDynamic | Should -BeTrue
			$s.TraceFlags | Should -Be @(3226)
			$s.TraceFlagsRead | Should -BeTrue
			$script:failFlags = $true
			$s2 = Get-sqmConfigOptionSet -SqlInstance 'SRV'
			$s2.TraceFlagsRead | Should -BeFalse
			@($s2.TraceFlags).Count | Should -Be 0
		}
	}
}

Describe 'Save-sqmConfigBaseline und Compare-sqmConfigBaseline' {
	BeforeEach {
		InModuleScope sqmSQLTool {
			Mock Invoke-sqmLogging { }
			Mock Invoke-sqmOpenReport { }
		}
	}

	It 'speichert eine Baseline und laedt sie im File-Modus wieder: Selbstvergleich = 0 Zeilen' {
		$dir = $script:TestDir
		InModuleScope sqmSQLTool -Parameters @{ Dir = $dir } {
			param ($Dir)
			Mock Get-sqmConfigOptionSet { New-CfgSet -Flags @(3226) }
			$b = Save-sqmConfigBaseline -SqlInstance 'SRV' -Label 'x' -OutputPath $Dir
			Test-Path $b.BaselinePath | Should -BeTrue
			$b.BaselinePath | Should -Match 'ConfigBaseline_T1_v16_'
			$b.OptionCount | Should -Be 3
			$b.TraceFlagCount | Should -Be 1
			@(Compare-sqmConfigBaseline -BaselinePath $b.BaselinePath -ComparePath $b.BaselinePath -NoReport).Count | Should -Be 0
		}
	}

	It 'Live-Modus: meldet Drift gegen die Baseline und schreibt TXT/HTML-Report' {
		$dir = $script:TestDir
		InModuleScope sqmSQLTool -Parameters @{ Dir = $dir } {
			param ($Dir)
			$script:call = 0
			Mock Get-sqmConfigOptionSet {
				$script:call++
				if ($script:call -eq 1) { New-CfgSet }
				else { New-CfgSet -Opt @{ 'xp_cmdshell' = @(1, 1, $true, $true) } -Flags @(3226) }
			}
			$b = Save-sqmConfigBaseline -SqlInstance 'SRV' -OutputPath $Dir
			$out = Join-Path $Dir 'cmp'
			$r = @(Compare-sqmConfigBaseline -BaselinePath $b.BaselinePath -SqlInstance 'SRV' -OutputPath $out -NoOpen)
			$r.Count | Should -Be 2
			($r | Where-Object Setting -eq 'xp_cmdshell').Status | Should -Be 'Critical'
			@(Get-ChildItem $out -Filter '*.html').Count | Should -Be 1
			(Get-Content (Get-ChildItem $out -Filter '*.txt' | Select-Object -First 1).FullName -Raw) | Should -Match 'xp_cmdshell'
		}
	}

	It 'warnt bei unterschiedlicher Hauptversion und liefert eine Version-Zeile' {
		$dir = $script:TestDir
		InModuleScope sqmSQLTool -Parameters @{ Dir = $dir } {
			param ($Dir)
			$script:call = 0
			Mock Get-sqmConfigOptionSet { $script:call++; if ($script:call -eq 1) { New-CfgSet -Major 16 } else { New-CfgSet -Major 17 } }
			$b = Save-sqmConfigBaseline -SqlInstance 'SRV' -OutputPath $Dir
			$r = @(Compare-sqmConfigBaseline -BaselinePath $b.BaselinePath -SqlInstance 'SRV' -NoReport -WarningAction SilentlyContinue)
			$r.Count | Should -Be 1
			$r[0].Category | Should -Be 'Version'
		}
	}

	It 'wirft mit -EnableException bei fehlender Baseline-Datei und nennt den Pfad' {
		InModuleScope sqmSQLTool {
			{ Compare-sqmConfigBaseline -BaselinePath 'C:\gibt\es\nicht.json' -ComparePath 'C:\x.json' -EnableException -NoReport } |
				Should -Throw -ExpectedMessage '*Baseline-Datei nicht gefunden: C:\gibt\es\nicht.json*'
		}
	}

	It 'Save-sqmConfigBaseline wirft mit -EnableException bei Verbindungsfehler' {
		InModuleScope sqmSQLTool {
			Mock Get-sqmConfigOptionSet { throw 'Verbindung verweigert' }
			{ Save-sqmConfigBaseline -SqlInstance 'SRV' -OutputPath $env:TEMP -EnableException } |
				Should -Throw -ExpectedMessage '*Verbindung verweigert*'
		}
	}
}

Describe 'Compare-sqmServerConfiguration -AllConfigOptions' {
	It 'haengt ConfigOption- und TraceFlag-Zeilen an und gibt bereits geprueftes (xp_cmdshell, MaxDop) nicht doppelt aus' {
		InModuleScope sqmSQLTool {
			Mock Invoke-sqmLogging { }
			Mock Connect-DbaInstance {
				$cv = { param ($v) [PSCustomObject]@{ ConfigValue = $v } }
				[PSCustomObject]@{
					VersionString = '16.0'; Edition = 'Dev'; ProductLevel = 'RTM'; HostPlatform = 'Windows'; Collation = 'X'; LoginMode = 'Mixed'
					IsClustered = $false; IsHadrEnabled = $false; BackupDirectory = 'C:\b'; DefaultFile = 'C:\d'; DefaultLog = 'C:\l'; ErrorLogPath = 'C:\e'; MasterDBPath = 'C:\m'
					Configuration = [PSCustomObject]@{
						MaxServerMemory = (& $cv 1); MinServerMemory = (& $cv 0); MaxDegreeOfParallelism = (& $cv 0); CostThresholdForParallelism = (& $cv 5)
						XPCmdShell = (& $cv 0); IsSqlClrEnabled = (& $cv 0); DefaultLanguage = (& $cv 0); DefaultFullTextLanguage = (& $cv 0)
					}
				}
			}
			$script:call = 0
			Mock Get-sqmConfigOptionSet {
				$script:call++
				if ($script:call -eq 1) { New-CfgSet }
				else { New-CfgSet -Opt @{ 'xp_cmdshell' = @(1, 1, $true, $true); 'max degree of parallelism' = @(8, 8, $true, $false); 'user connections' = @(50, 50, $false, $true) } -Flags @(3226) }
			}
			$r = @(Compare-sqmServerConfiguration -SourceInstance 'A' -TargetInstance 'B' -AllConfigOptions -NoReport)
			($r | Where-Object Category -eq 'ConfigOption').Setting | Should -Be 'user connections'
			($r | Where-Object Category -eq 'TraceFlag').Setting | Should -Be 'Trace Flag 3226'
			@($r | Where-Object Setting -eq 'xp_cmdshell').Count | Should -Be 0

			$script:call = 0
			$r2 = @(Compare-sqmServerConfiguration -SourceInstance 'A' -TargetInstance 'B' -NoReport)
			@($r2 | Where-Object Category -in 'ConfigOption', 'TraceFlag').Count | Should -Be 0
		}
	}
}
