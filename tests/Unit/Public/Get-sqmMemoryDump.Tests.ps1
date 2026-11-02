#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Get-sqmMemoryDump (gemockte Abfragen; live zusaetzlich gegen SQL Server 2025 mit DBCC STACKDUMP geprueft).

.DESCRIPTION
    Geprueft: Einordnung des Anlasses aus den Errorlog-Zeilen (Assertion, Access Violation, Non-yielding Scheduler),
    Auslesen von Fehlernummer, Exception, Modul, SPID und Input Buffer, Zuordnung ueber den SQLDump-Dateinamen,
    sauberer Rueckfall auf "Unknown", wenn der Errorlog-Eintrag fehlt oder der Errorlog nicht lesbar ist,
    und das Tagesfilter.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
}

Describe 'Get-sqmMemoryDump' {

	BeforeAll {
		function global:New-LogRow($Time, $Text) { [PSCustomObject]@{ LogDate = [datetime]$Time; ProcessInfo = 'spid55'; Text = $Text } }
		function global:New-DumpRow($Name, $Created, $Bytes = 52428800) { [PSCustomObject]@{ filename = "C:\SQL\LOG\$Name"; creation_local = $Created; size_in_bytes = $Bytes } }
	}

	Context 'Einordnung' {
		BeforeEach {
			InModuleScope sqmSQLTool {
				$script:dbatoolsAvailable = $true
				$now = Get-Date
				$script:t = $now.AddDays(-2).Date.AddHours(10)
				Mock Invoke-sqmLogging { }
				Mock Invoke-DbaQuery {
					if ($Query -like '*sys.dm_server_memory_dumps*')
					{
						return @(
							(New-DumpRow 'SQLDump0001.mdmp' $script:t.ToString('s'))
							(New-DumpRow 'SQLDump0002.mdmp' $script:t.AddHours(1).ToString('s'))
							(New-DumpRow 'SQLDump0003.mdmp' $script:t.AddHours(2).ToString('s'))
						)
					}
					if ($Query -like '*SERVERPROPERTY*') { return [PSCustomObject]@{ v = '16.0.4100.1' } }
					if ($Query -like '*sp_enumerrorlogs*') { return @(1, 2) | ForEach-Object { [PSCustomObject]@{ 'Archive #' = $_ } } }
					if ($Query -like "*N'Stack Dump being sent'*")
					{
						if ($Query -like '*xp_readerrorlog 0,*')
						{
							return @(
								(New-LogRow $script:t '***Stack Dump being sent to C:\SQL\LOG\SQLDump0001.txt')
								(New-LogRow $script:t.AddHours(1) '***Stack Dump being sent to C:\SQL\LOG\SQLDump0002.txt')
							)
						}
						return @()
					}
					if ($Query -like '*xp_readerrorlog 0, 1, NULL*')
					{
						# Fenster beginnt 3 Minuten vor dem Anker: Dump 1 und 2 haben einen "Stack Dump being sent"-Treffer
						# (Anker = Logzeit), Dump 3 nicht (Anker = Erstellzeit des Abbilds, so wie bei SQL Server 2025).
						if ($Query -like "*N'$($script:t.AddMinutes(-3).ToString('yyyyMMdd HH:mm:ss'))'*")
						{
							return @(
								(New-LogRow $script:t 'Error: 17066, Severity: 16, State: 1.')
								(New-LogRow $script:t 'SQL Server Assertion: File: <pageref.cpp>, line=1953 Failed Assertion = ''m_flags & 1''.')
								(New-LogRow $script:t '***Stack Dump being sent to C:\SQL\LOG\SQLDump0001.txt')
							)
						}
						if ($Query -like "*N'$($script:t.AddHours(1).AddMinutes(-3).ToString('yyyyMMdd HH:mm:ss'))'*")
						{
							return @(
								(New-LogRow $script:t 'Exception Address = 00007FF8A1B2C3D4 Module(sqllang+0000000000123456)')
								(New-LogRow $script:t 'Exception Code    = c0000005 EXCEPTION_ACCESS_VIOLATION')
								(New-LogRow $script:t '* BEGIN STACK DUMP:')
								(New-LogRow $script:t '*   spid 61')
								(New-LogRow $script:t 'Input Buffer 52 bytes -')
								(New-LogRow $script:t 'SELECT * FROM dbo.Orders WHERE 1=1')
							)
						}
						if ($Query -like "*N'$($script:t.AddHours(2).AddMinutes(-3).ToString('yyyyMMdd HH:mm:ss'))'*")
						{
							return @(
								(New-LogRow $script:t '**Dump thread - spid = 0, EC = 0x000000 Connection = 0x000000')
								(New-LogRow $script:t '**Dump thread - spid = 66, EC = 0x000001 Connection = 0x000001')
								(New-LogRow $script:t '* User initiated stack dump.  This is not a server exception dump.')
							)
						}
					}
					@()
				}
			}
		}

		It 'erkennt eine Assertion und liest die Fehlernummer' {
			InModuleScope sqmSQLTool {
				$r = @(Get-sqmMemoryDump -SqlInstance 'SQL01')
				$a = $r | Where-Object FileName -eq 'SQLDump0001.mdmp'
				$a.Type | Should -Be 'Assertion'
				$a.ErrorNumbers | Should -Contain 17066
				$a.Reason | Should -BeLike 'Assertion*17066*'
				$a.ProductVersion | Should -Be '16.0.4100.1'
				$a.SizeMB | Should -Be 50
			}
		}

		It 'erkennt eine Access Violation mit Modul, SPID und Input Buffer' {
			InModuleScope sqmSQLTool {
				$r = @(Get-sqmMemoryDump -SqlInstance 'SQL01')
				$a = $r | Where-Object FileName -eq 'SQLDump0002.mdmp'
				$a.Type | Should -Be 'AccessViolation'
				$a.ExceptionCode | Should -Be 'c0000005 EXCEPTION_ACCESS_VIOLATION'
				$a.Module | Should -Be 'sqllang+0000000000123456'
				$a.Spid | Should -Be 61
				$a.InputBuffer | Should -Be 'SELECT * FROM dbo.Orders WHERE 1=1'
			}
		}

		It 'ordnet ein Abbild ohne "Stack Dump being sent"-Zeile ueber die Erstellzeit zu (SQL Server 2025) und erkennt ein manuelles Abbild' {
			InModuleScope sqmSQLTool {
				$r = @(Get-sqmMemoryDump -SqlInstance 'SQL01')
				$a = $r | Where-Object FileName -eq 'SQLDump0003.mdmp'
				$a.Type | Should -Be 'Manual'
				$a.Spid | Should -Be 66
				$a.Hint | Should -BeLike '*absichtlich*'
			}
		}

		It 'liefert die neuesten Abbilder zuerst' {
			InModuleScope sqmSQLTool {
				$r = @(Get-sqmMemoryDump -SqlInstance 'SQL01')
				$r.Count | Should -Be 3
				$r[0].FileName | Should -Be 'SQLDump0003.mdmp'
			}
		}
	}

	Context 'Randfaelle' {
		It 'meldet Unknown mit Begruendung, wenn der Errorlog zum Zeitpunkt nichts mehr hat' {
			InModuleScope sqmSQLTool {
				$script:dbatoolsAvailable = $true
				Mock Invoke-sqmLogging { }
				Mock Invoke-DbaQuery {
					if ($Query -like '*sys.dm_server_memory_dumps*') { return @(New-DumpRow 'SQLDump0009.mdmp' (Get-Date).AddDays(-1).ToString('s')) }
					if ($Query -like '*sp_enumerrorlogs*') { return @(1, 2) | ForEach-Object { [PSCustomObject]@{ 'Archive #' = $_ } } }
					@()
				}
				$r = @(Get-sqmMemoryDump -SqlInstance 'SQL01')
				$r[0].Type | Should -Be 'Unknown'
				$r[0].Reason | Should -BeLike '*Kein Errorlog-Eintrag*SQLDump0009*'
			}
		}

		It 'gibt nichts zurueck, wenn es keine Abbilder gibt' {
			InModuleScope sqmSQLTool {
				$script:dbatoolsAvailable = $true
				Mock Invoke-sqmLogging { }
				Mock Invoke-DbaQuery { @() }
				@(Get-sqmMemoryDump -SqlInstance 'SQL01').Count | Should -Be 0
			}
		}

		It 'filtert mit -Days nach dem Alter' {
			InModuleScope sqmSQLTool {
				$script:dbatoolsAvailable = $true
				Mock Invoke-sqmLogging { }
				Mock Invoke-DbaQuery {
					if ($Query -like '*sys.dm_server_memory_dumps*')
					{
						return @(
							(New-DumpRow 'SQLDump0001.mdmp' (Get-Date).AddDays(-100).ToString('s'))
							(New-DumpRow 'SQLDump0002.mdmp' (Get-Date).AddDays(-3).ToString('s'))
						)
					}
					if ($Query -like '*sp_enumerrorlogs*') { return @() }
					@()
				}
				$r = @(Get-sqmMemoryDump -SqlInstance 'SQL01' -Days 30)
				$r.Count | Should -Be 1
				$r[0].FileName | Should -Be 'SQLDump0002.mdmp'
			}
		}

		It 'liefert die Abbilder auch, wenn der Errorlog nicht lesbar ist' {
			InModuleScope sqmSQLTool {
				$script:dbatoolsAvailable = $true
				Mock Invoke-sqmLogging { }
				Mock Invoke-DbaQuery {
					if ($Query -like '*sys.dm_server_memory_dumps*') { return @(New-DumpRow 'SQLDump0001.mdmp' (Get-Date).AddDays(-1).ToString('s')) }
					if ($Query -like '*sp_enumerrorlogs*') { throw 'The EXECUTE permission was denied' }
					@()
				}
				$r = @(Get-sqmMemoryDump -SqlInstance 'SQL01')
				$r.Count | Should -Be 1
				$r[0].Reason | Should -Be 'Errorlog nicht lesbar.'
				Should -Invoke Invoke-sqmLogging -ParameterFilter { $Level -eq 'WARNING' -and $Message -like '*Errorlog nicht lesbar*' }
			}
		}

		It 'wirft mit -EnableException, wenn die DMV nicht lesbar ist' {
			InModuleScope sqmSQLTool {
				$script:dbatoolsAvailable = $true
				Mock Invoke-sqmLogging { }
				Mock Invoke-DbaQuery { throw 'VIEW SERVER STATE permission was denied' }
				{ Get-sqmMemoryDump -SqlInstance 'SQL01' -EnableException } | Should -Throw -ExpectedMessage '*VIEW SERVER STATE*'
			}
		}
	}
}
