#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmAgRedoDiagnosis und die Entscheidungslogik Get-sqmAgRedoVerdict.
    Invoke-DbaQuery wird gemockt - getestet wird die Auswertung (CPU-Deltas, Wait-Anteile,
    Urteil), nicht das SQL.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
	InModuleScope sqmSQLTool { $script:dbatoolsAvailable = $true }
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
	$env:SQMSQLTOOL_SKIP_AUTO_UPDATE = $null
}

Describe 'Get-sqmAgRedoVerdict' {
	BeforeAll {
		# Basiswerte: grosser Rueckstand, nichts auffaellig. Einzelne Werte pro Fall ueberschreiben.
		function script:New-Metrics ([hashtable]$Override = @{ })
		{
			$m = [ordered]@{
				RedoQueueMB = 250000; TrendMBPerMin = 100; IsSuspended = $false; SuspendReason = ''
				DispatcherFound = $true; DispatcherCpuPct = 40; HelperCount = 4; AvgHelperCpuPct = 40; MaxHelperCpuPct = 50
				RunnableShare = 0; BlockedShare = 0; PageIoWaitShare = 0; LogReadWaitShare = 0
				DependencyWaitShare = 0; IdleShare = 0.1; AvgRunnableTasks = 0
			}
			foreach ($k in $Override.Keys) { $m[$k] = $Override[$k] }
			[PSCustomObject]$m
		}
	}

	It '<Expected> bei <Name>' -ForEach @(
		@{ Name = 'kleiner Queue'; Expected = 'NoBacklog'; Override = @{ RedoQueueMB = 10 } }
		@{ Name = 'Suspend'; Expected = 'Suspended'; Override = @{ IsSuspended = $true; SuspendReason = 'SUSPEND_FROM_USER' } }
		@{ Name = 'fehlendem Redo-Thread'; Expected = 'NoRedoTask'; Override = @{ DispatcherFound = $false } }
		@{ Name = 'Lock-Waits'; Expected = 'BlockedByQuery'; Override = @{ BlockedShare = 0.5 } }
		@{ Name = 'einem Redo-Thread ohne Helfer auf Volllast'; Expected = 'SingleThreadedRedo'; Override = @{ HelperCount = 0; DispatcherCpuPct = 95; AvgHelperCpuPct = 0; MaxHelperCpuPct = 0 } }
		@{ Name = 'runnable Redo-Threads'; Expected = 'SchedulerPressure'; Override = @{ RunnableShare = 0.4 } }
		@{ Name = 'tiefen Scheduler-Runnable-Queues'; Expected = 'SchedulerPressure'; Override = @{ AvgRunnableTasks = 3 } }
		@{ Name = 'PAGEIOLATCH-Waits'; Expected = 'PageReadIO'; Override = @{ PageIoWaitShare = 0.6 } }
		@{ Name = 'Log-Cache-Waits'; Expected = 'LogReadIO'; Override = @{ LogReadWaitShare = 0.6 } }
		@{ Name = 'Commit-Ordering-Waits'; Expected = 'TransactionDependency'; Override = @{ DependencyWaitShare = 0.7 } }
		@{ Name = 'Dispatcher voll, Helfer idle'; Expected = 'DispatchBound'; Override = @{ DispatcherCpuPct = 98; AvgHelperCpuPct = 5; MaxHelperCpuPct = 9; IdleShare = 0.7 } }
		@{ Name = 'einem gesaettigten Helfer'; Expected = 'WorkerSkew'; Override = @{ DispatcherCpuPct = 30; AvgHelperCpuPct = 25; MaxHelperCpuPct = 99 } }
		@{ Name = 'allen Helfern auf Volllast'; Expected = 'ApplyCpuBound'; Override = @{ AvgHelperCpuPct = 90; MaxHelperCpuPct = 95 } }
		@{ Name = 'untaetigen Redo-Threads trotz Rueckstand'; Expected = 'RedoIdle'; Override = @{ DispatcherCpuPct = 5; AvgHelperCpuPct = 3; MaxHelperCpuPct = 4; IdleShare = 0.9 } }
		@{ Name = 'unauffaelligen Werten'; Expected = 'Inconclusive'; Override = @{ } }
	) {
		$r = InModuleScope sqmSQLTool -Parameters @{ M = (New-Metrics $Override) } { Get-sqmAgRedoVerdict -Metrics $M }
		$r.Verdict | Should -Be $Expected
		$r.Evidence | Should -Match 'RedoQueue='
		$r.Recommendation | Should -Not -BeNullOrEmpty
	}

	It 'Blockierung hat Vorrang vor Scheduler- und I/O-Anzeichen' {
		$r = InModuleScope sqmSQLTool -Parameters @{ M = (New-Metrics @{ BlockedShare = 0.3; RunnableShare = 0.5; PageIoWaitShare = 0.5 }) } { Get-sqmAgRedoVerdict -Metrics $M }
		$r.Verdict | Should -Be 'BlockedByQuery'
	}

	It 'MinRedoQueueMB verschiebt die Schwelle fuer NoBacklog' {
		$r = InModuleScope sqmSQLTool -Parameters @{ M = (New-Metrics @{ RedoQueueMB = 500 }) } { Get-sqmAgRedoVerdict -Metrics $M -MinRedoQueueMB 1000 }
		$r.Verdict | Should -Be 'NoBacklog'
	}
}

Describe 'Get-sqmAgRedoDiagnosis' {
	Context 'Parameter' {
		It 'SampleSeconds ist auf 10-3600 begrenzt' {
			{ Get-sqmAgRedoDiagnosis -SampleSeconds 5 } | Should -Throw -ExpectedMessage '*SampleSeconds*'
		}
		It 'IntervalSeconds ist auf 1-60 begrenzt' {
			{ Get-sqmAgRedoDiagnosis -IntervalSeconds 0 } | Should -Throw -ExpectedMessage '*IntervalSeconds*'
		}
	}

	Context 'Secondary mit grossem Redo-Rueckstand, Dispatcher-Thread auf Volllast' {
		BeforeAll {
			$global:sqmRdSw = [System.Diagnostics.Stopwatch]::StartNew()
			Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
			Mock -ModuleName sqmSQLTool Start-Sleep { [System.Threading.Thread]::Sleep(400) }
			Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_hadr_database_replica_states' } {
				[PSCustomObject]@{
					DatabaseName = 'SalesDB'; DatabaseId = 5; AgName = 'AG1'; Role = 'SECONDARY'
					RedoQueueKB = [long](262144000 + $global:sqmRdSw.ElapsedMilliseconds); RedoRateKBs = 20000; SendQueueKB = 5120
					IsSuspended = 0; SuspendReason = ''
				}
				[PSCustomObject]@{
					DatabaseName = 'OtherDB'; DatabaseId = 6; AgName = 'AG1'; Role = 'SECONDARY'
					RedoQueueKB = 1024; RedoRateKBs = 500; SendQueueKB = 0; IsSuspended = 0; SuspendReason = ''
				}
			}
			Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_exec_requests' } {
				[PSCustomObject]@{ SessionId = 30; DatabaseId = 5; Command = 'DB STARTUP'; Status = 'running'; WaitType = ''; BlockingSessionId = 0; CpuMs = [long]$global:sqmRdSw.ElapsedMilliseconds }
				foreach ($s in 31..33)
				{
					[PSCustomObject]@{ SessionId = $s; DatabaseId = 5; Command = 'PARALLEL REDO TASK'; Status = 'suspended'; WaitType = 'PARALLEL_REDO_WORKER_WAIT_WORK'; BlockingSessionId = 0; CpuMs = 100 }
				}
			}
			Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_os_schedulers' } { [PSCustomObject]@{ AvgRunnable = 0.1 } }
			Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_os_wait_stats' } {
				[PSCustomObject]@{ WaitType = 'PARALLEL_REDO_WORKER_WAIT_WORK'; WaitTimeMs = [long](1000 * $global:sqmRdSw.ElapsedMilliseconds) }
				[PSCustomObject]@{ WaitType = 'PAGEIOLATCH_SH'; WaitTimeMs = 5 }
			}
			$script:res = @(Get-sqmAgRedoDiagnosis -SqlInstance 'SQL02' -SampleSeconds 10 -IntervalSeconds 1 -Quiet)
		}

		AfterAll {
			Remove-Variable sqmRdSw -Scope Global -ErrorAction SilentlyContinue
		}

		It 'liefert eine Zeile je Secondary-Datenbank, groesster Rueckstand zuerst' {
			$script:res.Count | Should -Be 2
			$script:res[0].DatabaseName | Should -Be 'SalesDB'
		}

		It 'erkennt Dispatch-Bound aus CPU-Delta und idlen Helfern' {
			$r = $script:res[0]
			$r.Verdict | Should -Be 'DispatchBound'
			$r.DispatcherCpuPct | Should -BeGreaterThan 80
			$r.HelperCount | Should -Be 3
			$r.AvgHelperCpuPct | Should -BeLessThan 5
		}

		It 'rechnet Queue in MB und den Trend' {
			$r = $script:res[0]
			$r.RedoQueueMB | Should -BeGreaterThan 250000
			$r.SendQueueMB | Should -Be 5
			$r.TrendMBPerMin | Should -BeGreaterThan 0
			$r.DrainEtaMinutes | Should -BeNullOrEmpty
		}

		It 'bewertet die kleine Datenbank als NoBacklog' {
			$script:res[1].Verdict | Should -Be 'NoBacklog'
		}

		It 'nennt die Wartezeiten der Instanz' {
			$script:res[0].InstanceTopWaits | Should -Match 'PARALLEL_REDO_WORKER_WAIT_WORK'
		}
	}

	Context 'Primaer-Replikat' {
		BeforeAll {
			Mock -ModuleName sqmSQLTool Invoke-sqmLogging { }
			Mock -ModuleName sqmSQLTool Start-Sleep { [System.Threading.Thread]::Sleep(400) }
			Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_hadr_database_replica_states' } {
				[PSCustomObject]@{
					DatabaseName = 'SalesDB'; DatabaseId = 5; AgName = 'AG1'; Role = 'PRIMARY'
					RedoQueueKB = 0; RedoRateKBs = 0; SendQueueKB = 0; IsSuspended = 0; SuspendReason = ''
				}
			}
			Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_exec_requests' } { }
			Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_os_schedulers' } { [PSCustomObject]@{ AvgRunnable = 0 } }
			Mock -ModuleName sqmSQLTool Invoke-DbaQuery -ParameterFilter { $Query -match 'dm_os_wait_stats' } { }
		}

		It 'warnt und liefert nichts, wenn keine Datenbank Secondary ist' {
			$r = @(Get-sqmAgRedoDiagnosis -SqlInstance 'SQL01' -SampleSeconds 10 -IntervalSeconds 1 -Quiet -WarningVariable w -WarningAction SilentlyContinue)
			$r.Count | Should -Be 0
			($w -join ' ') | Should -Match 'Secondary'
		}
	}
}
