#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmIndexHealth, Get-sqmStatisticsHealth und die Fortschrittsausgabe von
    Invoke-sqmIndexOptimize / Invoke-sqmUpdateStatistics. Invoke-DbaQuery/Get-DbaDatabase werden
    gemockt - getestet wird die Bewertung und die Ausgabe, nicht das SQL.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
	$env:SQMSQLTOOL_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmIndexHealth' {
	BeforeEach {
		Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
		Mock -ModuleName sqmSQLTool Get-DbaDatabase { [PSCustomObject]@{ Name = 'Shop'; IsAccessible = $true } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_db_index_usage_stats' } {
			function Inv ($n, $id, $type, $pages, $disabled = 0, $part = 1, $pc = 1) {
				[PSCustomObject]@{
					SchemaName = 'dbo'; TableName = 'T'; IndexName = $n; IndexId = $id; IndexType = $type
					IndexTypeDesc = $(if ($type -eq 5) { 'CLUSTERED COLUMNSTORE' } else { 'NONCLUSTERED' })
					IsDisabled = $disabled; FillFactor = 90; PartitionNumber = $part; PartitionCount = $pc
					Rows = 1000; PageCount = $pages; Reads = 5; Updates = 7
				}
			}
			Inv 'IX_Ok' 2 2 5000
			Inv 'IX_Mid' 3 2 5000
			Inv 'IX_High' 4 2 5000
			Inv 'IX_Small' 5 2 10
			Inv 'IX_Off' 6 2 5000 1
			Inv 'CCI' 1 5 5000
			Inv 'IX_P1' 7 2 5000 0 1 2
			Inv 'IX_P2' 7 2 5000 0 2 2
		}
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_db_index_physical_stats' } {
			function Fr ($id, $f, $part = 1) { [PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'T'; IndexId = $id; PartitionNumber = $part; FragmentationPercent = $f } }
			Fr 2 1.5
			Fr 3 12
			Fr 4 80
			Fr 7 40 2
			Fr 7 2 1
		}
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'HasCs' } { [PSCustomObject]@{ HasCs = 1 } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'column_store_row_group_physical_stats' -and $Query -notmatch 'HasCs' } {
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'T'; IndexId = 1; PartitionNumber = 1; FragmentationPercent = 25 }
		}
	}

	It 'bewertet Status nach denselben Schwellen wie Invoke-sqmIndexOptimize' {
		$r = @{ }; Get-sqmIndexHealth -SqlInstance 'SQL01' -OutputPath '' | ForEach-Object { $r["$($_.Index)|$($_.Partition)"] = $_ }
		$r['IX_Ok|'].Status | Should -Be 'Ok'
		$r['IX_Mid|'].Status | Should -Be 'Reorganize'
		$r['IX_High|'].Status | Should -Be 'Rebuild'
		$r['IX_Small|'].Status | Should -Be 'Small'
		$r['IX_Off|'].Status | Should -Be 'Disabled'
		$r['CCI|'].Status | Should -Be 'Reorganize'          # 25 % geloescht >= 20 %
		$r['IX_P1|1'].Status | Should -Be 'Ok'
		$r['IX_P2|2'].Status | Should -Be 'Rebuild'
		$r['IX_Mid|'].SizeMB | Should -Be 39.1
	}

	It '-OnlyProblems zeigt nur Reorganize/Rebuild' {
		$r = @(Get-sqmIndexHealth -SqlInstance 'SQL01' -OnlyProblems -OutputPath '')
		$r.Count | Should -Be 4
		($r | Where-Object { $_.Status -notin 'Reorganize', 'Rebuild' }).Count | Should -Be 0
	}

	It '-SkipFragmentation liest keine Seiten' {
		$r = @(Get-sqmIndexHealth -SqlInstance 'SQL01' -SkipFragmentation -OutputPath '')
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_db_index_physical_stats' } -Times 0
		($r | Where-Object { $_.Status -notin 'NotMeasured', 'Disabled' }).Count | Should -Be 0
	}

	It '-Summary liefert eine Zeile je Datenbank' {
		$r = @(Get-sqmIndexHealth -SqlInstance 'SQL01' -Summary -OutputPath '')
		$r.Count | Should -Be 1
		$r[0].Database | Should -Be 'Shop'
		$r[0].Indexes | Should -Be 8
		$r[0].Rebuild | Should -Be 2
		$r[0].Disabled | Should -Be 1
	}

	It 'Low >= High wird abgelehnt' {
		{ Get-sqmIndexHealth -SqlInstance 'SQL01' -FragmentationLow 30 -FragmentationHigh 30 -OutputPath '' } | Should -Throw -ExpectedMessage '*muss kleiner*'
	}
}

Describe 'Get-sqmStatisticsHealth' {
	BeforeEach {
		Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
		Mock -ModuleName sqmSQLTool Get-DbaDatabase { [PSCustomObject]@{ Name = 'Shop'; IsAccessible = $true } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'persisted_sample_percent' -and $Query -match 'all_columns' } { [PSCustomObject]@{ N = 1 } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'is_auto_update_stats_on' } { [PSCustomObject]@{ AutoUpdate = 0; AutoUpdateAsync = 0; AutoCreate = 1 } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'FROM sys.stats' } {
			$n = [DBNull]::Value
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'Big'; StatName = 'S_Big'; IsIndexStat = 1; NoRecompute = 0; IsFiltered = 0; Rows = 100000000; RowsSampled = 1000000; Steps = 200; ModCounter = 400000; LastUpdated = [datetime]'2030-01-01'; AgeDays = 1; PersistedSamplePercent = $n }
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'Big'; StatName = 'S_BigLow'; IsIndexStat = 0; NoRecompute = 1; IsFiltered = 0; Rows = 100000000; RowsSampled = 1000000; Steps = 200; ModCounter = 1000; LastUpdated = [datetime]'2030-01-01'; AgeDays = 1; PersistedSamplePercent = $n }
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'Old'; StatName = 'S_Old'; IsIndexStat = 1; NoRecompute = 0; IsFiltered = 1; Rows = 50000000; RowsSampled = 50000000; Steps = 200; ModCounter = 10; LastUpdated = [datetime]'2029-01-01'; AgeDays = 40; PersistedSamplePercent = $n }
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'Quiet'; StatName = 'S_Quiet'; IsIndexStat = 1; NoRecompute = 0; IsFiltered = 0; Rows = 1000; RowsSampled = 1000; Steps = 5; ModCounter = 0; LastUpdated = [datetime]'2030-01-01'; AgeDays = 1; PersistedSamplePercent = $n }
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'Never'; StatName = 'S_Never'; IsIndexStat = 0; NoRecompute = 0; IsFiltered = 0; Rows = $n; RowsSampled = $n; Steps = $n; ModCounter = $n; LastUpdated = $n; AgeDays = $n; PersistedSamplePercent = $n }
		}
	}

	It 'entscheidet NeedsUpdate wie Invoke-sqmUpdateStatistics' {
		$r = @{ }; Get-sqmStatisticsHealth -SqlInstance 'SQL01' -OutputPath '' | ForEach-Object { $r[$_.Statistic] = $_ }
		$r['S_Big'].Status | Should -Be 'Stale'
		$r['S_Big'].NeedsUpdate | Should -Be $true
		$r['S_Big'].Reason | Should -Match '^Threshold'
		$r['S_Big'].SamplePercent | Should -Be 1
		$r['S_BigLow'].NeedsUpdate | Should -Be $false                     # 1000 < SQRT(1000*100M)
		$r['S_BigLow'].Status | Should -Be 'NoRecompute'
		$r['S_Old'].Reason | Should -Match '^Age'
		$r['S_Quiet'].Status | Should -Be 'Ok'
		$r['S_Never'].Status | Should -Be 'NeverUpdated'
		$r['S_Never'].NeedsUpdate | Should -Be $false
	}

	It 'liefert die Datenbank-Einstellungen mit' {
		$r = @(Get-sqmStatisticsHealth -SqlInstance 'SQL01' -OutputPath '')
		$r[0].AutoUpdateStats | Should -Be $false
		$r[0].AutoCreateStats | Should -Be $true
	}

	It '-OnlyProblems blendet Ok aus' {
		$r = @(Get-sqmStatisticsHealth -SqlInstance 'SQL01' -OnlyProblems -OutputPath '')
		$r.Statistic | Should -Not -Contain 'S_Quiet'
		$r.Count | Should -Be 4
	}

	It '-Summary zaehlt je Datenbank' {
		$r = @(Get-sqmStatisticsHealth -SqlInstance 'SQL01' -Summary -OutputPath '')
		$r.Count | Should -Be 1
		$r[0].Statistics | Should -Be 5
		$r[0].Stale | Should -Be 2
		$r[0].NeverUpdated | Should -Be 1
	}
}

Describe 'Fortschrittsausgabe der Wartungsfunktionen' {
	BeforeEach {
		Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
		Mock -ModuleName sqmSQLTool Write-Progress { }
		Mock -ModuleName sqmSQLTool Get-DbaDatabase { [PSCustomObject]@{ Name = 'Shop'; IsAccessible = $true } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'EngineEdition' } { [PSCustomObject]@{ EngineEdition = 3; MajorVersion = 16; Edition = 'Test' } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'Updateability' } { [PSCustomObject]@{ Updateability = 'READ_WRITE' } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'HasCs' } { [PSCustomObject]@{ HasCs = 0 } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_db_index_physical_stats' } {
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'T'; IndexName = 'IX_High'; IndexId = 2; IndexType = 2; IndexTypeDesc = 'NONCLUSTERED'; AllowPageLocks = 1; PartitionNumber = 1; PartitionCount = 1; PageCount = 5000; FragmentationPercent = 80 }
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'T'; IndexName = 'IX_Mid'; IndexId = 3; IndexType = 2; IndexTypeDesc = 'NONCLUSTERED'; AllowPageLocks = 1; PartitionNumber = 1; PartitionCount = 1; PageCount = 5000; FragmentationPercent = 12 }
		}
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match '^ALTER INDEX' } { }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'persisted_sample_percent' -and $Query -match 'all_columns' } { [PSCustomObject]@{ N = 0 } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'FROM sys.stats' } {
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'T'; StatName = 'S1'; IsIndexStat = 1; NoRecompute = 0; Rows = 1000; ModCounter = 500; LastUpdated = [datetime]'2030-01-01'; AgeDays = 1; PersistedSamplePercent = [DBNull]::Value }
		}
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match '^UPDATE STATISTICS' } { }
	}

	It 'Invoke-sqmIndexOptimize meldet Datenbank, Index und Abschluss' {
		$out = Invoke-sqmIndexOptimize -SqlInstance 'SQL01' 6>&1
		$text = ($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
		$text | Should -Match '\[Shop\] 2 Index-Operation'
		$text | Should -Match '\[1/2\] Success REBUILD ONLINE dbo\.T\.IX_High'
		$text | Should -Match '\[2/2\] Success REORGANIZE dbo\.T\.IX_Mid'
		$text | Should -Match 'abgeschlossen .*2 erfolgreich, 0 fehlgeschlagen'
		@($out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }).Count | Should -Be 2
		Should -Invoke -ModuleName sqmSQLTool Write-Progress -Times 1 -ParameterFilter { $Id -eq 2 -and $Status -match '1/2' }
	}

	It 'Invoke-sqmUpdateStatistics meldet je Statistik' {
		$out = Invoke-sqmUpdateStatistics -SqlInstance 'SQL01' 6>&1
		$text = ($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n"
		$text | Should -Match '\[Shop\] 1 Statistik\(en\) zu aktualisieren'
		$text | Should -Match '\[1/1\] Success dbo\.T\.S1'
		$text | Should -Match '\[Shop\] fertig: 1 aktualisiert'
	}

	It '-Quiet unterdrueckt Konsole und Fortschrittsbalken' {
		$o1 = Invoke-sqmIndexOptimize -SqlInstance 'SQL01' -Quiet 6>&1
		$o2 = Invoke-sqmUpdateStatistics -SqlInstance 'SQL01' -Quiet 6>&1
		@($o1 + $o2 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }).Count | Should -Be 0
		Should -Invoke -ModuleName sqmSQLTool Write-Progress -Times 0
	}

	It 'WhatIf schreibt keine Fortschrittszeilen' {
		$o = Invoke-sqmIndexOptimize -SqlInstance 'SQL01' -WhatIf 6>&1
		@($o | Where-Object { $_ -is [System.Management.Automation.InformationRecord] -and "$($_.MessageData)" -match 'Success|fertig|abgeschlossen' }).Count | Should -Be 0
	}
}
