#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Set-sqmTempDbFileSize (gemockte Abfragen; live zusaetzlich gegen SQL Server 2025 geprueft).

.DESCRIPTION
    Geprueft: Zielgroesse = groesste Datei, nur kleinere Dateien werden angefasst, SIZE und FILEGROWTH gehen in
    getrennten Anweisungen raus (MODIFY FILE erlaubt nur eine Eigenschaft), -WhatIf aendert nichts, und die
    Vorabpruefungen (MAXSIZE, freier Platz, Zielgroesse kleiner als die groesste Datei) brechen ab, bevor
    irgendeine Datei veraendert wurde.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
}

Describe 'Set-sqmTempDbFileSize' {

	BeforeAll {
		# size/max_size sind Seiten zu 8 KB: 12800 Seiten = 100 MB.
		function global:New-TempFile($Id, $Name, $Pages, $MaxPages = -1, $Growth = 8192, $Percent = 0)
		{
			[PSCustomObject]@{ file_id = $Id; name = $Name; physical_name = "T:\tempdb\$Name.ndf"; size = $Pages; max_size = $MaxPages; growth = $Growth; is_percent_growth = $Percent }
		}
	}

	Context 'Angleichen' {
		BeforeEach {
			InModuleScope sqmSQLTool {
				$script:dbatoolsAvailable = $true
				$script:executed = [System.Collections.Generic.List[string]]::new()
				Mock Invoke-sqmLogging { }
				Mock Invoke-DbaQuery {
					if ($Query -like '*sys.dm_os_volume_stats*')
					{
						return @(1, 2, 3 | ForEach-Object { [PSCustomObject]@{ file_id = $_; volume_mount_point = 'T:\'; available_bytes = [long]100GB } })
					}
					if ($Query -like 'ALTER DATABASE*') { $script:executed.Add($Query); return }
					@(
						(New-TempFile 1 'tempdev' 12800)
						(New-TempFile 2 'tempdev2' 5120)
						(New-TempFile 3 'tempdev3' 12800)
					)
				}
			}
		}

		It 'vergroessert nur die kleineren Dateien auf die Groesse der groessten' {
			InModuleScope sqmSQLTool {
				$r = @(Set-sqmTempDbFileSize -SqlInstance 'SQL01')
				($r | Where-Object Status -eq 'Changed').LogicalName | Should -Be 'tempdev2'
				($r | Where-Object Status -eq 'Unchanged').Count | Should -Be 2
				$script:executed.Count | Should -Be 1
				$script:executed[0] | Should -Be "ALTER DATABASE tempdb MODIFY FILE (NAME = N'tempdev2', SIZE = 102400KB);"
			}
		}

		It 'schickt SIZE und FILEGROWTH als getrennte Anweisungen' {
			InModuleScope sqmSQLTool {
				Set-sqmTempDbFileSize -SqlInstance 'SQL01' -FileGrowthMB 32 | Out-Null
				$script:executed | Where-Object { $_ -match 'SIZE' -and $_ -match 'FILEGROWTH' } | Should -BeNullOrEmpty
				@($script:executed | Where-Object { $_ -match 'FILEGROWTH = 32768KB' }).Count | Should -Be 3
				@($script:executed | Where-Object { $_ -match 'SIZE = 102400KB' }).Count | Should -Be 1
			}
		}

		It 'aendert mit -WhatIf nichts' {
			InModuleScope sqmSQLTool {
				$r = @(Set-sqmTempDbFileSize -SqlInstance 'SQL01' -WhatIf)
				$script:executed.Count | Should -Be 0
				($r | Where-Object Status -eq 'WhatIf').LogicalName | Should -Be 'tempdev2'
			}
		}

		It 'verwendet -TargetSizeMB, wenn es nicht kleiner als die groesste Datei ist' {
			InModuleScope sqmSQLTool {
				Set-sqmTempDbFileSize -SqlInstance 'SQL01' -TargetSizeMB 200 | Out-Null
				$script:executed.Count | Should -Be 3
				$script:executed | ForEach-Object { $_ | Should -Match 'SIZE = 204800KB' }
			}
		}

		It 'lehnt -TargetSizeMB unter der groessten Datei ab, ohne etwas zu aendern' {
			InModuleScope sqmSQLTool {
				{ Set-sqmTempDbFileSize -SqlInstance 'SQL01' -TargetSizeMB 50 -EnableException } | Should -Throw -ExpectedMessage '*kleiner als die groesste Datei*'
				$script:executed.Count | Should -Be 0
			}
		}
	}

	Context 'Vorabpruefungen' {
		It 'bricht ab, wenn eine Datei ein zu kleines MAXSIZE hat' {
			InModuleScope sqmSQLTool {
				$script:dbatoolsAvailable = $true
				$script:executed = [System.Collections.Generic.List[string]]::new()
				Mock Invoke-sqmLogging { }
				Mock Invoke-DbaQuery {
					if ($Query -like '*sys.dm_os_volume_stats*') { return @() }
					if ($Query -like 'ALTER DATABASE*') { $script:executed.Add($Query); return }
					@((New-TempFile 1 'tempdev' 12800), (New-TempFile 2 'tempdev2' 5120 7680))
				}
				{ Set-sqmTempDbFileSize -SqlInstance 'SQL01' -EnableException } | Should -Throw -ExpectedMessage '*MAXSIZE zu klein*tempdev2*'
				$script:executed.Count | Should -Be 0
			}
		}

		It 'bricht ab, wenn der freie Platz nicht reicht' {
			InModuleScope sqmSQLTool {
				$script:dbatoolsAvailable = $true
				$script:executed = [System.Collections.Generic.List[string]]::new()
				Mock Invoke-sqmLogging { }
				Mock Invoke-DbaQuery {
					if ($Query -like '*sys.dm_os_volume_stats*')
					{
						return @(1, 2 | ForEach-Object { [PSCustomObject]@{ file_id = $_; volume_mount_point = 'T:\'; available_bytes = [long]10MB } })
					}
					if ($Query -like 'ALTER DATABASE*') { $script:executed.Add($Query); return }
					@((New-TempFile 1 'tempdev' 12800), (New-TempFile 2 'tempdev2' 5120))
				}
				{ Set-sqmTempDbFileSize -SqlInstance 'SQL01' -EnableException } | Should -Throw -ExpectedMessage "*Nicht genug freier Platz*T:*"
				$script:executed.Count | Should -Be 0
			}
		}

		It 'macht ohne Fehler weiter, wenn der Platzcheck mangels Recht nicht moeglich ist' {
			InModuleScope sqmSQLTool {
				$script:dbatoolsAvailable = $true
				$script:executed = [System.Collections.Generic.List[string]]::new()
				Mock Invoke-sqmLogging { }
				Mock Invoke-DbaQuery {
					if ($Query -like '*sys.dm_os_volume_stats*') { throw 'VIEW SERVER STATE permission was denied' }
					if ($Query -like 'ALTER DATABASE*') { $script:executed.Add($Query); return }
					@((New-TempFile 1 'tempdev' 12800), (New-TempFile 2 'tempdev2' 5120))
				}
				$r = @(Set-sqmTempDbFileSize -SqlInstance 'SQL01')
				($r | Where-Object Status -eq 'Changed').LogicalName | Should -Be 'tempdev2'
				Should -Invoke Invoke-sqmLogging -ParameterFilter { $Level -eq 'WARNING' -and $Message -like '*Platzcheck uebersprungen*' }
			}
		}
	}
}
