#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Set-sqmTempDbFileCount (gemockte Abfragen).

.DESCRIPTION
    Geprueft: fehlende Dateien werden mit der Groesse der groessten Datei im Ordner der ersten Datei angelegt,
    Namen und Pfade belegter Dateien werden uebersprungen, die Standardanzahl kommt aus den Kernen der Zielinstanz
    (max MaxFiles), bei erreichter oder ueberschrittener Anzahl passiert nichts, -WhatIf aendert nichts und ein
    zu kleines Ziellaufwerk bricht vor der ersten Aenderung ab.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
}

Describe 'Set-sqmTempDbFileCount' {

	BeforeAll {
		# size/growth sind Seiten zu 8 KB: 12800 Seiten = 100 MB, 8192 Seiten = 64 MB.
		function global:New-CountFile($Id, $Name, $Pages, $Growth = 8192, $Percent = 0)
		{
			[PSCustomObject]@{ file_id = $Id; name = $Name; physical_name = "T:\tempdb\$Name.ndf"; size = $Pages; growth = $Growth; is_percent_growth = $Percent }
		}
	}

	Context 'Anlegen' {
		BeforeEach {
			InModuleScope sqmSQLTool {
				$script:dbatoolsAvailable = $true
				$script:executed = [System.Collections.Generic.List[string]]::new()
				Mock Invoke-sqmLogging { }
				Mock Get-sqmConfig { $null }
				Mock Invoke-DbaQuery {
					if ($Query -like '*dm_os_sys_info*') { return [PSCustomObject]@{ Cpu = 4 } }
					if ($Query -like '*sys.dm_os_volume_stats*') { return [PSCustomObject]@{ volume_mount_point = 'T:\'; available_bytes = [long]100GB } }
					if ($Query -like 'ALTER DATABASE*') { $script:executed.Add($Query); return }
					@((New-CountFile 1 'tempdev' 12800), (New-CountFile 2 'temp2' 5120))
				}
			}
		}

		It 'legt auf die Kernzahl der Zielinstanz auf, mit Groesse der groessten Datei' {
			InModuleScope sqmSQLTool {
				$r = @(Set-sqmTempDbFileCount -SqlInstance 'SQL01')
				$r.Count | Should -Be 2
				($r.Status | Select-Object -Unique) | Should -Be 'Created'
				$r.LogicalName | Should -Be @('temp3', 'temp4')
				$r[-1].NewFileCount | Should -Be 4
				$script:executed.Count | Should -Be 2
				$script:executed[0] | Should -Be "ALTER DATABASE tempdb ADD FILE (NAME = N'temp3', FILENAME = N'T:\tempdb\tempdb_mssql_3.ndf', SIZE = 102400KB, FILEGROWTH = 65536KB);"
			}
		}

		It 'begrenzt die Standardanzahl auf MaxFiles' {
			InModuleScope sqmSQLTool {
				$r = @(Set-sqmTempDbFileCount -SqlInstance 'SQL01' -MaxFiles 3)
				$r.Count | Should -Be 1
				$r[0].NewFileCount | Should -Be 3
			}
		}

		It 'uebernimmt -FileCount, -Path und -FileGrowthMB' {
			InModuleScope sqmSQLTool {
				Set-sqmTempDbFileCount -SqlInstance 'SQL01' -FileCount 3 -Path 'U:\TempDB\' -FileGrowthMB 128 | Out-Null
				$script:executed.Count | Should -Be 1
				$script:executed[0] | Should -Match 'FILENAME = N''U:\\TempDB\\tempdb_mssql_3\.ndf'''
				$script:executed[0] | Should -Match 'FILEGROWTH = 131072KB'
			}
		}

		It 'ersetzt Prozentwachstum der ersten Datei durch 64 MB' {
			InModuleScope sqmSQLTool {
				Mock Invoke-DbaQuery {
					if ($Query -like '*sys.dm_os_volume_stats*') { return [PSCustomObject]@{ volume_mount_point = 'T:\'; available_bytes = [long]100GB } }
					if ($Query -like 'ALTER DATABASE*') { $script:executed.Add($Query); return }
					@((New-CountFile 1 'tempdev' 12800 10 1))
				}
				Set-sqmTempDbFileCount -SqlInstance 'SQL01' -FileCount 2 | Out-Null
				$script:executed[0] | Should -Match 'FILEGROWTH = 65536KB'
			}
		}

		It 'ueberspringt belegte Namen' {
			InModuleScope sqmSQLTool {
				Mock Invoke-DbaQuery {
					if ($Query -like '*sys.dm_os_volume_stats*') { return [PSCustomObject]@{ volume_mount_point = 'T:\'; available_bytes = [long]100GB } }
					if ($Query -like 'ALTER DATABASE*') { $script:executed.Add($Query); return }
					@((New-CountFile 1 'tempdev' 12800), (New-CountFile 3 'temp3' 12800))
				}
				$r = @(Set-sqmTempDbFileCount -SqlInstance 'SQL01' -FileCount 3)
				$r[0].LogicalName | Should -Be 'temp2'
			}
		}

		It 'aendert mit -WhatIf nichts' {
			InModuleScope sqmSQLTool {
				$r = @(Set-sqmTempDbFileCount -SqlInstance 'SQL01' -WhatIf)
				($r.Status | Select-Object -Unique) | Should -Be 'WhatIf'
				$script:executed.Count | Should -Be 0
			}
		}

		It 'meldet Skipped und aendert nichts, wenn die Anzahl schon erreicht ist' {
			InModuleScope sqmSQLTool {
				$r = @(Set-sqmTempDbFileCount -SqlInstance 'SQL01' -FileCount 2)
				$r.Count | Should -Be 1
				$r[0].Status | Should -Be 'Skipped'
				$script:executed.Count | Should -Be 0
			}
		}

		It 'meldet Skipped statt Dateien zu entfernen, wenn es schon mehr sind' {
			InModuleScope sqmSQLTool {
				$r = @(Set-sqmTempDbFileCount -SqlInstance 'SQL01' -FileCount 1)
				$r[0].Status | Should -Be 'Skipped'
				$r[0].Message | Should -BeLike '*Entfernen wird nicht unterstuetzt*'
				$script:executed.Count | Should -Be 0
			}
		}

		It 'gleicht mit -EqualizeSize ueber Set-sqmTempDbFileSize an' {
			InModuleScope sqmSQLTool {
				Mock Set-sqmTempDbFileSize { }
				Set-sqmTempDbFileCount -SqlInstance 'SQL01' -EqualizeSize | Out-Null
				Should -Invoke Set-sqmTempDbFileSize -Times 1 -Exactly
			}
		}

		It 'bricht ab, wenn das Ziellaufwerk zu klein ist' {
			InModuleScope sqmSQLTool {
				Mock Invoke-DbaQuery {
					if ($Query -like '*dm_os_sys_info*') { return [PSCustomObject]@{ Cpu = 4 } }
					if ($Query -like '*sys.dm_os_volume_stats*') { return [PSCustomObject]@{ volume_mount_point = 'T:\'; available_bytes = [long]150MB } }
					if ($Query -like 'ALTER DATABASE*') { $script:executed.Add($Query); return }
					@((New-CountFile 1 'tempdev' 12800), (New-CountFile 2 'temp2' 5120))
				}
				{ Set-sqmTempDbFileCount -SqlInstance 'SQL01' -EnableException } | Should -Throw -ExpectedMessage '*Nicht genug freier Platz*T:*'
				$script:executed.Count | Should -Be 0
			}
		}

		It 'meldet Failed und legt keine weiteren Dateien an, wenn ADD FILE scheitert' {
			InModuleScope sqmSQLTool {
				Mock Invoke-DbaQuery {
					if ($Query -like '*dm_os_sys_info*') { return [PSCustomObject]@{ Cpu = 4 } }
					if ($Query -like '*sys.dm_os_volume_stats*') { return [PSCustomObject]@{ volume_mount_point = 'T:\'; available_bytes = [long]100GB } }
					if ($Query -like 'ALTER DATABASE*') { $script:executed.Add($Query); throw 'Directory lookup failed' }
					@((New-CountFile 1 'tempdev' 12800), (New-CountFile 2 'temp2' 5120))
				}
				$r = @(Set-sqmTempDbFileCount -SqlInstance 'SQL01')
				$r.Count | Should -Be 1
				$r[0].Status | Should -Be 'Failed'
				$script:executed.Count | Should -Be 1
			}
		}
	}
}
