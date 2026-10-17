#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Invoke-sqmIndexOptimize, Invoke-sqmUpdateStatistics (adaptive Defaults) und
    Get-sqmLogReuseDiagnosis. Invoke-DbaQuery/Get-DbaDatabase werden gemockt - getestet wird die
    Entscheidungslogik (Aktion, ONLINE, Partition, Schwelle, Stichprobe, Ursache). Die echten
    Abfragen sind live gegen SQL Server 2022 (DEV01) geprueft.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule

	function script:New-IdxRow
	{
		param ([string]$Index, [double]$Frag, [int]$Type = 2, [int]$Pages = 5000, [int]$PartCount = 1, [int]$Part = 1, [int]$PageLocks = 1)
		[PSCustomObject]@{
			SchemaName = 'dbo'; TableName = 'T'; IndexName = $Index; IndexId = 2; IndexType = $Type
			IndexTypeDesc = $(if ($Type -eq 1) { 'CLUSTERED' } elseif ($Type -eq 3) { 'XML' } else { 'NONCLUSTERED' })
			AllowPageLocks = $PageLocks; PartitionNumber = $Part; PartitionCount = $PartCount; PageCount = $Pages; FragmentationPercent = $Frag
		}
	}
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
	$env:SQMSQLTOOL_SKIP_AUTO_UPDATE = $null
}

Describe 'Invoke-sqmIndexOptimize' {
	BeforeEach {
		Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
		Mock -ModuleName sqmSQLTool Get-DbaDatabase { [PSCustomObject]@{ Name = 'Shop'; IsAccessible = $true } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'EngineEdition' } { [PSCustomObject]@{ EngineEdition = $script:engine; MajorVersion = 16; Edition = 'Test' } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'Updateability' } { [PSCustomObject]@{ Updateability = 'READ_WRITE' } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'HasCs' } { [PSCustomObject]@{ HasCs = 0 } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_db_index_physical_stats' } {
			New-IdxRow -Index 'IX_Mid' -Frag 12
			New-IdxRow -Index 'IX_High' -Frag 80
			New-IdxRow -Index 'IX_NoLocks' -Frag 12 -PageLocks 0
			New-IdxRow -Index 'CX_Part' -Type 1 -Frag 50 -PartCount 4 -Part 3
			New-IdxRow -Index 'XML_Idx' -Type 3 -Frag 60
		}
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match '^ALTER INDEX' } { }
		$script:engine = 3
	}

	It 'Enterprise: REORGANIZE ab Low, REBUILD ONLINE mit Low-Priority ab High, Partition einzeln' {
		$r = @{ }; Invoke-sqmIndexOptimize -SqlInstance 'SQL01' | ForEach-Object { $r[$_.Index] = $_ }
		$r['IX_Mid'].Action | Should -Be 'REORGANIZE'
		$r['IX_Mid'].Command | Should -Match 'REORGANIZE WITH \(LOB_COMPACTION = ON\)'
		$r['IX_High'].Action | Should -Be 'REBUILD ONLINE'
		$r['IX_High'].Command | Should -Match 'WAIT_AT_LOW_PRIORITY \(MAX_DURATION = 1 MINUTES, ABORT_AFTER_WAIT = SELF\)'
		$r['IX_NoLocks'].Action | Should -Be 'REBUILD ONLINE'      # REORGANIZE ohne Page Locks unmoeglich
		$r['CX_Part'].Command | Should -Match 'REBUILD PARTITION = 3 WITH'
		$r['CX_Part'].Partition | Should -Be 3
		$r['XML_Idx'].Action | Should -Be 'REBUILD OFFLINE'        # XML-Index nicht ONLINE
		$r['IX_High'].Status | Should -Be 'Success'
	}

	It 'Standard ohne Offline-Rebuild: REORGANIZE statt Rebuild, Skipped wenn beides unmoeglich' {
		$script:engine = 2
		$r = @{ }; Invoke-sqmIndexOptimize -SqlInstance 'SQL01' -AllowOfflineRebuild $false | ForEach-Object { $r[$_.Index] = $_ }
		$r['IX_High'].Action | Should -Be 'REORGANIZE'
		$r['IX_NoLocks'].Status | Should -Be 'Skipped'
	}

	It 'FillFactor nur bei ganzen Indizes, nicht bei Partition-Rebuild' {
		$r = @{ }; Invoke-sqmIndexOptimize -SqlInstance 'SQL01' -FillFactor 90 -Online Off | ForEach-Object { $r[$_.Index] = $_ }
		$r['IX_High'].Command | Should -Match 'FILLFACTOR = 90'
		$r['CX_Part'].Command | Should -Not -Match 'FILLFACTOR'
	}

	It 'WhatIf fuehrt nichts aus' {
		$r = @(Invoke-sqmIndexOptimize -SqlInstance 'SQL01' -WhatIf)
		$r.Count | Should -Be 5
		($r | Where-Object Status -ne 'WhatIf').Count | Should -Be 0
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match '^ALTER INDEX' } -Times 0
	}

	It 'Lock-Abbruch (Low Priority) wird Failed, kein Offline-Nachholen' {
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match '^ALTER INDEX \[IX_High\]' } { throw 'Lock request time out period exceeded.' }
		$r = @{ }; Invoke-sqmIndexOptimize -SqlInstance 'SQL01' | ForEach-Object { $r[$_.Index] = $_ }
		$r['IX_High'].Status | Should -Be 'Failed'
		$r['IX_High'].Action | Should -Be 'REBUILD ONLINE'
		$r['IX_Mid'].Status | Should -Be 'Success'
	}

	It 'Low >= High wird abgelehnt' {
		{ Invoke-sqmIndexOptimize -SqlInstance 'SQL01' -FragmentationLow 30 -FragmentationHigh 30 } | Should -Throw
	}
}

Describe 'Invoke-sqmUpdateStatistics (adaptiv)' {
	BeforeEach {
		Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
		Mock -ModuleName sqmSQLTool Get-DbaDatabase { [PSCustomObject]@{ Name = 'Shop'; IsAccessible = $true } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'Updateability' } { [PSCustomObject]@{ Updateability = 'READ_WRITE' } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'persisted_sample_percent' -and $Query -match 'all_columns' } { [PSCustomObject]@{ N = 1 } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'FROM sys.stats' } {
			$n = [DBNull]::Value
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'Big'; StatName = 'S_Big'; IsIndexStat = 1; NoRecompute = 0; Rows = 100000000; ModCounter = 400000; LastUpdated = [datetime]'2030-01-01'; AgeDays = 1; PersistedSamplePercent = $n }
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'Big'; StatName = 'S_BigLow'; IsIndexStat = 0; NoRecompute = 1; Rows = 100000000; ModCounter = 1000; LastUpdated = [datetime]'2030-01-01'; AgeDays = 1; PersistedSamplePercent = $n }
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'Small'; StatName = 'S_Small'; IsIndexStat = 1; NoRecompute = 1; Rows = 1000; ModCounter = 150; LastUpdated = [datetime]'2030-01-01'; AgeDays = 1; PersistedSamplePercent = $n }
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'Old'; StatName = 'S_Old'; IsIndexStat = 1; NoRecompute = 0; Rows = 50000000; ModCounter = 10; LastUpdated = [datetime]'2029-01-01'; AgeDays = 40; PersistedSamplePercent = $n }
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'Pers'; StatName = 'S_Pers'; IsIndexStat = 1; NoRecompute = 0; Rows = 50000000; ModCounter = 5000000; LastUpdated = [datetime]'2030-01-01'; AgeDays = 1; PersistedSamplePercent = 7.5 }
			[PSCustomObject]@{ SchemaName = 'dbo'; TableName = 'Never'; StatName = 'S_Never'; IsIndexStat = 1; NoRecompute = 0; Rows = $n; ModCounter = $n; LastUpdated = $n; AgeDays = $n; PersistedSamplePercent = $n }
		}
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match '^UPDATE STATISTICS' } { }
	}

	It 'Schwelle, Alter, Stichprobe und NORECOMPUTE' {
		$r = @{ }; Invoke-sqmUpdateStatistics -SqlInstance 'SQL01' | ForEach-Object { $r[$_.Statistic] = $_ }
		$r.Keys.Count | Should -Be 4
		$r['S_Big'].Option | Should -Be 'SAMPLE 1 PERCENT'                  # 100 M Zeilen: Ziel 1 M Zeilen = 1 %
		$r['S_Big'].Reason | Should -Match '^Threshold'
		$r.ContainsKey('S_BigLow') | Should -Be $false                      # 1000 < SQRT(1000*100M)
		$r['S_Small'].Option | Should -Be 'FULLSCAN, NORECOMPUTE'           # 150 >= 10 % von 1000
		$r['S_Old'].Reason | Should -Match '^Age'
		$r['S_Old'].Option | Should -Be 'SAMPLE 2 PERCENT'
		$r['S_Pers'].Option | Should -Be 'SAMPLE 8 PERCENT, PERSIST_SAMPLE_PERCENT = ON'
		$r['S_Big'].Status | Should -Be 'Success'
	}

	It 'Feste Stichprobe und Any = altes Verhalten' {
		$r = @{ }; Invoke-sqmUpdateStatistics -SqlInstance 'SQL01' -SamplePercent 0 -ModificationThreshold Any | ForEach-Object { $r[$_.Statistic] = $_ }
		$r.Keys.Count | Should -Be 5
		$r['S_BigLow'].Option | Should -Be 'FULLSCAN, NORECOMPUTE'
		$r['S_Pers'].Option | Should -Be 'FULLSCAN'
	}

	It 'WhatIf fuehrt nichts aus' {
		$r = @(Invoke-sqmUpdateStatistics -SqlInstance 'SQL01' -WhatIf)
		$r.Count | Should -Be 4
		($r | Where-Object Status -ne 'WhatIf').Count | Should -Be 0
		Should -Invoke -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match '^UPDATE STATISTICS' } -Times 0
	}

	It 'Nicht beschreibbare Datenbank wird uebersprungen' {
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'Updateability' } { [PSCustomObject]@{ Updateability = 'READ_ONLY' } }
		@(Invoke-sqmUpdateStatistics -SqlInstance 'SQL01').Count | Should -Be 0
	}
}

Describe 'Get-sqmLogReuseDiagnosis' {
	BeforeEach {
		Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_db_log_space_usage' } {
			[PSCustomObject]@{ LogReuseWait = $script:wait; RecoveryModel = 'FULL'; IsPublished = 0; IsCdcEnabled = 0; LogSize_MB = 2048; LogUsed_Pct = 40 }
		}
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'FROM sys.database_files' } {
			[PSCustomObject]@{ FileId = 2; LogicalName = 'Shop_log'; Size_MB = 2048; IsPercentGrowth = 1; Growth = 10; MaxSize = -1 }
		}
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'HasLogInfo' } { [PSCustomObject]@{ HasLogInfo = 1 } }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_db_log_info\(DB_ID' } {
			# 1200 VLFs a 0,5 MB ab 8 KB, plus einer am Ende aktiv
			for ($i = 0; $i -lt 1199; $i++) { [PSCustomObject]@{ FileId = 2; BeginOffset = 8192 + $i * 524288; Size_MB = 0.5; IsActive = 0 } }
			[PSCustomObject]@{ FileId = 2; BeginOffset = 2047 * 1MB; Size_MB = 1; IsActive = 1 }
		}
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_tran_database_transactions' } { }
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'backupset' } { [PSCustomObject]@{ LastLogBackup = [DBNull]::Value } }
		$script:wait = 'LOG_BACKUP'
	}

	It 'LOG_BACKUP ohne Log-Backup, aktiver VLF am Ende, viele VLFs durch Prozent-Wachstum' {
		$d = InModuleScope sqmSQLTool { Get-sqmLogReuseDiagnosis -ConnParams @{ SqlInstance = 'SQL01' } -Database 'Shop' }
		$d.Cause | Should -Match 'Log-Backup.*nie'
		$d.Recommendation | Should -Match 'BackupType LOG'
		$d.VlfCount | Should -Be 1200
		$d.VlfStatus | Should -Be 'Critical'
		$d.VlfCause | Should -Match 'Prozentuales Wachstum \(10 %\)'
		$d.VlfRecommendation | Should -Match 'FILEGROWTH = 1024MB'
		$d.Files[0].ActiveEnd_MB | Should -Be 2048
		($d.Details -join ' ') | Should -Match 'am Dateiende'
	}

	It 'NOTHING, aber offene Transaktion: Transaktion wird als Ursache genannt' {
		$script:wait = 'NOTHING'
		Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_tran_database_transactions' } {
			[PSCustomObject]@{ SessionId = 71; LoginName = 'app'; HostName = 'WEB1'; ProgramName = 'Shop'; SessionStatus = 'sleeping'; BeginTime = [datetime]'2030-01-01 08:00'; AgeMinutes = 240; LogUsed_MB = 12.5 }
		}
		$d = InModuleScope sqmSQLTool { Get-sqmLogReuseDiagnosis -ConnParams @{ SqlInstance = 'SQL01' } -Database 'Shop' }
		$d.Cause | Should -Match 'Session 71 \(app von WEB1'
		$d.Recommendation | Should -Match 'Offene Transaktion'
	}
}
