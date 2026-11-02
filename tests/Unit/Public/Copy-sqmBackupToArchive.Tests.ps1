#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Copy-sqmBackupToArchive (gemockte msdb-Historie und robocopy).

.DESCRIPTION
    Geprueft: Zeitraum = zuletzt abgeschlossener Monat/Jahr, juengstes Full-Backup je Datenbank ueber alle AG-Replikate,
    Quelle ueber die Admin-Freigabe des schreibenden Knotens, alle Stripes werden kopiert, Zielstruktur, kein /MIR und /PURGE,
    Nicht-Disk-Backups werden uebersprungen, Datenbanken ohne Backup als NoBackup gemeldet, ein nicht lesbares Replikat bricht ab.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
}

Describe 'Copy-sqmBackupToArchive' {

	BeforeEach {
		InModuleScope sqmSQLTool {
			$script:dbatoolsAvailable = $true
			$script:roboCalls = [System.Collections.Generic.List[object]]::new()
			$script:histQueries = [System.Collections.Generic.List[string]]::new()
			Mock Invoke-sqmLogging { }
			Mock Invoke-sqmRobocopy { $script:roboCalls.Add($Arguments); [PSCustomObject]@{ ExitCode = 1; Output = @() } }
			function global:New-HistRow($Db, $Set, $Finish, $Path, $Type = 2)
			{
				[PSCustomObject]@{ DatabaseName = $Db; BackupSetId = $Set; BackupFinish = [datetime]$Finish; DevicePath = $Path; DeviceType = $Type }
			}
			# Zwei Replikate: NODE1 (lokal gefragt) und NODE2. SalesDB: spaeteres Backup liegt auf NODE2, zwei Stripes.
			Mock Invoke-DbaQuery {
				if ($Query -like '*sys.availability_replicas*') { return @([PSCustomObject]@{ ReplicaName = 'NODE1' }, [PSCustomObject]@{ ReplicaName = 'NODE2' }) }
				if ($Query -like '*FROM sys.databases*') { return @([PSCustomObject]@{ DatabaseName = 'SalesDB' }, [PSCustomObject]@{ DatabaseName = 'HrDB' }, [PSCustomObject]@{ DatabaseName = 'NoBackupDB' }) }
				$script:histQueries.Add($Query)
				if ("$SqlInstance" -eq 'NODE1')
				{
					return @(
						(New-HistRow 'SalesDB' 10 '2026-10-25 22:00' 'G:\Backup\SalesDB_old.bak')
						(New-HistRow 'HrDB' 11 '2026-10-31 23:00' 'G:\Backup\HrDB.bak')
						(New-HistRow 'master' 12 '2026-10-31 23:30' 'G:\Backup\master.bak')
					)
				}
				@(
					(New-HistRow 'SalesDB' 20 '2026-10-31 22:00' 'G:\Backup\SalesDB_1.bak')
					(New-HistRow 'SalesDB' 20 '2026-10-31 22:00' 'G:\Backup\SalesDB_2.bak')
				)
			}
		}
	}

	AfterAll {
		Remove-Item function:\global:New-HistRow -ErrorAction SilentlyContinue
	}

	It 'nimmt je Datenbank das juengste Full-Backup ueber alle Replikate und holt alle Stripes ueber die Admin-Freigabe des Knotens' {
		InModuleScope sqmSQLTool {
			$r = @(Copy-sqmBackupToArchive -SqlInstance 'NODE1' -Destination '\\fs\arch' -Period Month -ReferenceDate '2026-11-03')
			$sales = $r | Where-Object DatabaseName -eq 'SalesDB'
			$sales.SourceReplica | Should -Be 'NODE2'
			$sales.FileCount | Should -Be 2
			$sales.Status | Should -Be 'Copied'
			$sales.TargetPath | Should -Be '\\fs\arch\2026\2026-10\SalesDB'
			$script:roboCalls.Count | Should -Be 3
			$hits = 0
			foreach ($c in $script:roboCalls) { if ($c[0] -eq '\\NODE2\G$\Backup' -and $c[2] -eq 'SalesDB_2.bak') { $hits++ } }
			$hits | Should -Be 1
		}
	}

	It 'kopiert Backups des lokalen Knotens direkt, ohne Admin-Freigabe' {
		InModuleScope sqmSQLTool {
			Mock Invoke-DbaQuery {
				if ($Query -like '*sys.availability_replicas*') { return @() }
				if ($Query -like '*FROM sys.databases*') { return @() }
				@(New-HistRow 'SalesDB' 1 '2026-10-31 22:00' 'G:\Backup\SalesDB.bak')
			}
			Copy-sqmBackupToArchive -SqlInstance $env:COMPUTERNAME -Destination 'D:\arch' -Period Month -ReferenceDate '2026-11-03' | Out-Null
			$script:roboCalls[0][0] | Should -Be 'G:\Backup'
			$script:roboCalls[0][1] | Should -Be 'D:\arch\2026\2026-10\SalesDB'
		}
	}

	It 'laesst Systemdatenbanken weg, ausser mit -IncludeSystemDatabases' {
		InModuleScope sqmSQLTool {
			$r = @(Copy-sqmBackupToArchive -SqlInstance 'NODE1' -Destination '\\fs\arch' -Period Month -ReferenceDate '2026-11-03')
			$r.DatabaseName | Should -Not -Contain 'master'
			$r2 = @(Copy-sqmBackupToArchive -SqlInstance 'NODE1' -Destination '\\fs\arch' -Period Month -ReferenceDate '2026-11-03' -IncludeSystemDatabases)
			$r2.DatabaseName | Should -Contain 'master'
		}
	}

	It 'meldet Online-Benutzerdatenbanken ohne Backup im Zeitraum als NoBackup' {
		InModuleScope sqmSQLTool {
			$r = @(Copy-sqmBackupToArchive -SqlInstance 'NODE1' -Destination '\\fs\arch' -Period Month -ReferenceDate '2026-11-03')
			($r | Where-Object DatabaseName -eq 'NoBackupDB').Status | Should -Be 'NoBackup'
		}
	}

	It 'rechnet den Zeitraum Monat auf den Vormonat, auch ueber den Jahreswechsel' {
		InModuleScope sqmSQLTool {
			Copy-sqmBackupToArchive -SqlInstance 'NODE1' -Destination '\\fs\arch' -Period Month -ReferenceDate '2027-01-10' | Out-Null
			$script:histQueries[0] | Should -BeLike "*>= '20261201 00:00:00'*"
			$script:histQueries[0] | Should -BeLike "*< '20270101 00:00:00'*"
		}
	}

	It 'rechnet den Zeitraum Year auf das Vorjahr und legt ohne Monatsordner ab' {
		InModuleScope sqmSQLTool {
			$r = @(Copy-sqmBackupToArchive -SqlInstance 'NODE1' -Destination '\\fs\arch\' -Period Year -ReferenceDate '2027-03-01')
			$script:histQueries[0] | Should -BeLike "*>= '20260101 00:00:00'*"
			$script:histQueries[0] | Should -BeLike "*< '20270101 00:00:00'*"
			($r | Where-Object DatabaseName -eq 'HrDB').TargetPath | Should -Be '\\fs\arch\2026\HrDB'
		}
	}

	It 'ruft robocopy mit /XO, ohne /MIR und /PURGE auf' {
		InModuleScope sqmSQLTool {
			Copy-sqmBackupToArchive -SqlInstance 'NODE1' -Destination '\\fs\arch' -Period Month -ReferenceDate '2026-11-03' | Out-Null
			$a = @($script:roboCalls[0])
			$a | Should -Contain '/XO'
			$a | Should -Not -Contain '/MIR'
			$a | Should -Not -Contain '/PURGE'
		}
	}

	It 'meldet UpToDate, wenn robocopy nichts kopiert hat' {
		InModuleScope sqmSQLTool {
			Mock Invoke-sqmRobocopy { [PSCustomObject]@{ ExitCode = 0; Output = @() } }
			$r = @(Copy-sqmBackupToArchive -SqlInstance 'NODE1' -Destination '\\fs\arch' -Period Month -ReferenceDate '2026-11-03')
			($r | Where-Object DatabaseName -eq 'HrDB').Status | Should -Be 'UpToDate'
		}
	}

	It 'ueberspringt Backups, die nicht auf einem Datentraeger liegen' {
		InModuleScope sqmSQLTool {
			Mock Invoke-DbaQuery {
				if ($Query -like '*sys.availability_replicas*') { return @() }
				if ($Query -like '*FROM sys.databases*') { return @() }
				@(New-HistRow 'SalesDB' 1 '2026-10-31 22:00' 'https://acct.blob.core.windows.net/c/SalesDB.bak' 9)
			}
			$r = @(Copy-sqmBackupToArchive -SqlInstance 'NODE1' -Destination '\\fs\arch' -Period Month -ReferenceDate '2026-11-03')
			$r[0].Status | Should -Be 'Skipped'
			Should -Invoke Invoke-sqmRobocopy -Times 0
		}
	}

	It 'kopiert nichts mit -WhatIf' {
		InModuleScope sqmSQLTool {
			$r = @(Copy-sqmBackupToArchive -SqlInstance 'NODE1' -Destination '\\fs\arch' -Period Month -ReferenceDate '2026-11-03' -WhatIf)
			(@($r | Where-Object Status -eq 'WhatIf')).Count | Should -Be 2
			Should -Invoke Invoke-sqmRobocopy -Times 0
		}
	}

	It 'bricht ab, wenn ein Replikat nicht lesbar ist, und kopiert dann nichts' {
		InModuleScope sqmSQLTool {
			Mock Invoke-DbaQuery {
				if ($Query -like '*sys.availability_replicas*') { return @([PSCustomObject]@{ ReplicaName = 'NODE1' }, [PSCustomObject]@{ ReplicaName = 'NODE2' }) }
				if ("$SqlInstance" -eq 'NODE2') { throw 'Verbindung fehlgeschlagen' }
				@()
			}
			{ Copy-sqmBackupToArchive -SqlInstance 'NODE1' -Destination '\\fs\arch' -Period Month -EnableException } | Should -Throw -ExpectedMessage "*Replikat 'NODE2' nicht lesbar*"
			Should -Invoke Invoke-sqmRobocopy -Times 0
		}
	}

	It 'macht nach einem fehlgeschlagenen Kopieren weiter und wirft mit -EnableException erst am Ende' {
		InModuleScope sqmSQLTool {
			Mock Invoke-sqmRobocopy {
				$script:roboCalls.Add($Arguments)
				if ($Arguments[2] -eq 'HrDB.bak') { [PSCustomObject]@{ ExitCode = 16; Output = @('Zugriff verweigert') } }
				else { [PSCustomObject]@{ ExitCode = 1; Output = @() } }
			}
			{ Copy-sqmBackupToArchive -SqlInstance 'NODE1' -Destination '\\fs\arch' -Period Month -ReferenceDate '2026-11-03' -EnableException } | Should -Throw -ExpectedMessage '*HrDB*'
			($script:roboCalls | Where-Object { $_[2] -like 'SalesDB*' }).Count | Should -Be 2
		}
	}
}
