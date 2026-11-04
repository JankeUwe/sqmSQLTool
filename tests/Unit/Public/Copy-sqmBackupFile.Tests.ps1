#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Copy-sqmBackupFile (echte Dateien im TestDrive, der zweite Knoten gemockt).

.DESCRIPTION
    Geprueft: Ola-Struktur <Quelle>\<Datenbank>\FULL|DIFF|LOG mit Platzhalter, neueste Datei ueber beide Knoten (bei Gleichstand der lokale),
    Zielname (Quellname, {Database}/{Type}), Ueberschreiben nur mit -Overwrite, identisches Ziel = UpToDate, temporaere Datei wird
    aufgeraeumt, nicht erreichbarer Knoten bricht ab, -WhatIf kopiert nichts.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
}

Describe 'Copy-sqmBackupFile' {

	BeforeEach {
		$script:root = Join-Path $TestDrive ('src' + [guid]::NewGuid().ToString('N').Substring(0, 6))
		$script:src = Join-Path $script:root 'SERVER1$AG1'
		$script:dst = Join-Path $TestDrive ('dst' + [guid]::NewGuid().ToString('N').Substring(0, 6))
		foreach ($d in 'DB1\FULL', 'DB1\LOG', 'DB2\FULL')
		{
			New-Item -ItemType Directory -Path (Join-Path $script:src $d) -Force | Out-Null
		}
		function global:New-BakFile($Path, $Content, $Time)
		{
			Set-Content -LiteralPath $Path -Value $Content
			(Get-Item -LiteralPath $Path).LastWriteTime = [datetime]$Time
		}
		New-BakFile (Join-Path $script:src 'DB1\FULL\SERVER1$AG1_DB1_FULL_20261101_040000.bak') 'old' '2026-11-01 04:00'
		New-BakFile (Join-Path $script:src 'DB1\FULL\SERVER1$AG1_DB1_FULL_20261103_042816.bak') 'newest' '2026-11-03 04:28'
		New-BakFile (Join-Path $script:src 'DB1\LOG\SERVER1$AG1_DB1_LOG_20261103_050000.trn') 'log' '2026-11-03 05:00'
		New-BakFile (Join-Path $script:src 'DB2\FULL\SERVER1$AG1_DB2_FULL_20261102_030000.bak') 'db2' '2026-11-02 03:00'

		InModuleScope sqmSQLTool {
			$script:dbatoolsAvailable = $true
			Mock Invoke-sqmLogging { }
			# kein AG: nur der lokale Knoten
			Mock Invoke-DbaQuery { @() }
		}
	}

	AfterAll {
		Remove-Item function:\global:New-BakFile -ErrorAction SilentlyContinue
	}

	Context 'ein Knoten' {
		It 'waehlt per Platzhalter die neueste Datei und behaelt den Quellnamen' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				$r = @(Copy-sqmBackupFile -SourcePath $Src -Database DB1 -TargetPath $Dst)
				$r.Count | Should -Be 1
				$r[0].Status | Should -Be 'Copied'
				$name = 'SERVER1$AG1_DB1_FULL_20261103_042816.bak'
				(Join-Path $Dst $name) | Should -Exist
				Get-Content -LiteralPath (Join-Path $Dst $name) | Should -Be 'newest'
				(Get-Item -LiteralPath (Join-Path $Dst $name)).LastWriteTime | Should -Be ([datetime]'2026-11-03 04:28')
				@(Get-ChildItem -LiteralPath $Dst -Filter '*.tmp').Count | Should -Be 0
			}
		}

		It 'setzt {Database} und {Type} im Zielnamen und im Zielpfad ein' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				$r = @(Copy-sqmBackupFile -SourcePath $Src -Database DB1, DB2 -TargetPath "$Dst\{Database}" -TargetFile '{Database}_{Type}_Weekly.bak')
				$r.Status | Should -Be @('Copied', 'Copied')
				(Join-Path $Dst 'DB1\DB1_FULL_Weekly.bak') | Should -Exist
				(Join-Path $Dst 'DB2\DB2_FULL_Weekly.bak') | Should -Exist
			}
		}

		It 'nimmt bei Log den LOG-Ordner mit *.trn und kopiert Full und Log getrennt' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				$r = @(Copy-sqmBackupFile -SourcePath $Src -Database DB1 -BackupType Full, Log -TargetPath $Dst)
				$r.BackupType | Should -Be @('Full', 'Log')
				(Join-Path $Dst 'SERVER1$AG1_DB1_LOG_20261103_050000.trn') | Should -Exist
			}
		}

		It 'meldet NotFound, wenn nichts passt, und wirft mit -EnableException' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				$r = @(Copy-sqmBackupFile -SourcePath $Src -Database DB2 -BackupType Log -TargetPath $Dst -ErrorAction SilentlyContinue)
				$r[0].Status | Should -Be 'NotFound'
				{ Copy-sqmBackupFile -SourcePath $Src -Database NoSuchDb -TargetPath $Dst -EnableException } | Should -Throw -ExpectedMessage '*NoSuchDb*'
			}
		}

		It 'verwendet -SourceFile statt des Standardmusters' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				$r = @(Copy-sqmBackupFile -SourcePath $Src -Database DB1 -SourceFile '*20261101*.bak' -TargetPath $Dst)
				$r[0].SourceFile | Should -BeLike '*20261101_040000.bak'
			}
		}

		It 'kopiert nichts mit -WhatIf' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				$r = @(Copy-sqmBackupFile -SourcePath $Src -Database DB1 -TargetPath $Dst -WhatIf)
				$r[0].Status | Should -Be 'WhatIf'
				$Dst | Should -Not -Exist
			}
		}
	}

	Context 'vorhandenes Ziel' {
		It 'meldet UpToDate bei identischem Ziel (zweiter Lauf)' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				Copy-sqmBackupFile -SourcePath $Src -Database DB1 -TargetPath $Dst | Out-Null
				$r = @(Copy-sqmBackupFile -SourcePath $Src -Database DB1 -TargetPath $Dst)
				$r[0].Status | Should -Be 'UpToDate'
			}
		}

		It 'meldet Exists bei abweichendem Ziel ohne -Overwrite und laesst es unveraendert' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				New-Item -ItemType Directory -Path $Dst -Force | Out-Null
				Set-Content -LiteralPath (Join-Path $Dst 'week.bak') -Value 'previous'
				$r = @(Copy-sqmBackupFile -SourcePath $Src -Database DB1 -TargetPath $Dst -TargetFile 'week.bak' -ErrorAction SilentlyContinue)
				$r[0].Status | Should -Be 'Exists'
				Get-Content -LiteralPath (Join-Path $Dst 'week.bak') | Should -Be 'previous'
			}
		}

		It 'ersetzt das Ziel mit -Overwrite ueber eine temporaere Datei' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				New-Item -ItemType Directory -Path $Dst -Force | Out-Null
				Set-Content -LiteralPath (Join-Path $Dst 'week.bak') -Value 'previous'
				$r = @(Copy-sqmBackupFile -SourcePath $Src -Database DB1 -TargetPath $Dst -TargetFile 'week.bak' -Overwrite)
				$r[0].Status | Should -Be 'Copied'
				Get-Content -LiteralPath (Join-Path $Dst 'week.bak') | Should -Be 'newest'
				@(Get-ChildItem -LiteralPath $Dst -Filter '*.tmp').Count | Should -Be 0
			}
		}

		It 'raeumt die temporaere Datei auf, wenn das Umbenennen scheitert, und laesst das alte Ziel stehen' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				New-Item -ItemType Directory -Path $Dst -Force | Out-Null
				Set-Content -LiteralPath (Join-Path $Dst 'week.bak') -Value 'previous'
				Mock Move-Item { throw 'gesperrt' }
				$r = @(Copy-sqmBackupFile -SourcePath $Src -Database DB1 -TargetPath $Dst -TargetFile 'week.bak' -Overwrite -ErrorAction SilentlyContinue)
				$r[0].Status | Should -Be 'Failed'
				$r[0].Message | Should -BeLike '*gesperrt*'
				@(Get-ChildItem -LiteralPath $Dst -Filter '*.tmp').Count | Should -Be 0
				Get-Content -LiteralPath (Join-Path $Dst 'week.bak') | Should -Be 'previous'
			}
		}
	}

	Context 'zwei Knoten' {
		BeforeEach {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src } {
				param ($Src)
				$script:drive = $Src.Substring(0, 1)
				$script:remoteDir = "\\NODE2\$($script:drive)`$" + $Src.Substring(2) + '\DB1\FULL'
				$script:remoteTime = [datetime]'2026-11-04 04:30'
				Mock Test-sqmPathReachable { $true }
				# Pester faellt bei nicht passendem Filter nicht auf die echte Funktion zurueck: die lokale Variante ist der Standard-Mock.
				Mock Get-sqmNodeFile {
					if (Test-Path -LiteralPath $Directory -PathType Container) { Get-ChildItem -LiteralPath $Directory -Filter $Filter -File }
				}
				Mock Get-sqmNodeFile {
					[PSCustomObject]@{
						Name = 'SERVER1$AG1_DB1_FULL_20261104_043000.bak'
						FullName = "$($script:remoteDir)\SERVER1`$AG1_DB1_FULL_20261104_043000.bak"
						Length = 100
						LastWriteTime = $script:remoteTime
						LastWriteTimeUtc = $script:remoteTime.ToUniversalTime()
					}
				} -ParameterFilter { $Directory -like '\\NODE2*' }
				# Kopieren nur simulieren: haelt fest, von wo kopiert wurde, und legt das Ziel an.
				Mock Copy-Item {
					$script:copiedFrom = $LiteralPath
					Set-Content -LiteralPath $Destination -Value 'copied'
				}
			}
		}

		It 'nimmt die neuere Datei vom anderen Knoten und kopiert sie ueber die Admin-Freigabe' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				$r = @(Copy-sqmBackupFile -SourcePath $Src -Database DB1 -TargetPath $Dst -PartnerServer NODE2)
				$r[0].SourceNode | Should -Be 'NODE2'
				$r[0].Status | Should -Be 'Copied'
				$script:copiedFrom | Should -BeLike "\\NODE2\$($script:drive)`$*DB1\FULL\*20261104_043000.bak"
			}
		}

		It 'nimmt bei Gleichstand die lokale Datei' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				$script:remoteTime = [datetime]'2026-11-03 04:28'
				$r = @(Copy-sqmBackupFile -SourcePath $Src -Database DB1 -TargetPath $Dst -PartnerServer NODE2)
				$r[0].SourceNode | Should -Be $env:COMPUTERNAME
			}
		}

		It 'nimmt die lokale Datei, wenn sie neuer ist als die des anderen Knotens' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				$script:remoteTime = [datetime]'2026-11-02 01:00'
				$r = @(Copy-sqmBackupFile -SourcePath $Src -Database DB1 -TargetPath $Dst -PartnerServer NODE2)
				$r[0].SourceNode | Should -Be $env:COMPUTERNAME
				$r[0].SourceFile | Should -BeLike '*20261103_042816.bak'
			}
		}

		It 'bricht ab, wenn der andere Knoten nicht erreichbar ist, und kopiert nichts' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				Mock Test-sqmPathReachable { $false }
				{ Copy-sqmBackupFile -SourcePath $Src -Database DB1 -TargetPath $Dst -PartnerServer NODE2 -EnableException } | Should -Throw -ExpectedMessage "*NODE2*nicht erreichbar*"
				$Dst | Should -Not -Exist
			}
		}

		It 'ermittelt den anderen Knoten aus dem AG, wenn kein -PartnerServer angegeben ist' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				Mock Invoke-DbaQuery { @([PSCustomObject]@{ ReplicaName = 'NODE2\INST1' }) }
				$r = @(Copy-sqmBackupFile -SourcePath $Src -Database DB1 -TargetPath $Dst)
				$r[0].SourceNode | Should -Be 'NODE2'
				Should -Invoke Invoke-DbaQuery -ParameterFilter { $Query -like '*is_local = 0*' } -Times 1
			}
		}
	}

	Context 'Eingabepruefung' {
		It 'lehnt einen festen -TargetFile bei mehreren Dateien ohne Platzhalter ab' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				{ Copy-sqmBackupFile -SourcePath $Src -Database DB1, DB2 -TargetPath $Dst -TargetFile 'x.bak' -EnableException } | Should -Throw -ExpectedMessage '*Platzhalter*'
			}
		}

		It 'lehnt einen Pfad in -SourceFile ab' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:src; Dst = $script:dst } {
				param ($Src, $Dst)
				{ Copy-sqmBackupFile -SourcePath $Src -Database DB1 -SourceFile 'DB1\FULL\*.bak' -TargetPath $Dst -EnableException } | Should -Throw -ExpectedMessage '*keinen Pfad*'
			}
		}

		It 'lehnt einen UNC-Quellpfad ab' {
			InModuleScope sqmSQLTool {
				{ Copy-sqmBackupFile -SourcePath '\\srv\share' -Database DB1 -TargetPath 'C:\x' -EnableException } | Should -Throw -ExpectedMessage '*lokaler Pfad*'
			}
		}
	}
}
