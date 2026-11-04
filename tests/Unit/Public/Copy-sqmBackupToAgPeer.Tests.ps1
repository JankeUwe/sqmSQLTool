#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer Copy-sqmBackupToAgPeer (gemockte Replikatabfrage und robocopy).

.DESCRIPTION
    Geprueft: Partner kommen aus dem AG (Instanzteil entfernt, lokales Replikat nicht dabei), der Zielpfad ist die
    Admin-Freigabe mit gleichem Verzeichnis, robocopy bekommt /XO und kein /MIR oder /PURGE, Exitcodes unter 8 sind Erfolg,
    ab 8 Fehler (mit -EnableException eine Ausnahme nach dem letzten Partner), -WhatIf kopiert nichts.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
}

Describe 'Copy-sqmBackupToAgPeer' {

	BeforeEach {
		$script:src = Join-Path $TestDrive 'Backup'
		New-Item -ItemType Directory -Path $script:src -Force | Out-Null
		$script:srcPath = $script:src
	}

	Context 'Partner aus dem AG' {
		BeforeEach {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:srcPath } {
				param ($Src)
				$script:dbatoolsAvailable = $true
				$script:roboCalls = [System.Collections.Generic.List[object]]::new()
				Mock Invoke-sqmLogging { }
				# SourcePath muss ein Laufwerks-Pfad sein; TestDrive liegt auf einem solchen Laufwerk.
				Mock Invoke-DbaQuery { @([PSCustomObject]@{ ReplicaName = 'NODE2' }, [PSCustomObject]@{ ReplicaName = 'NODE3\INST1' }) }
				Mock Invoke-sqmRobocopy { $script:roboCalls.Add($Arguments); [PSCustomObject]@{ ExitCode = 1; Output = @('ok') } }
			}
		}

		It 'bildet die Zielpfade aus Partnername und Admin-Freigabe und entfernt den Instanzteil' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:srcPath } {
				param ($Src)
				$r = @(Copy-sqmBackupToAgPeer -SqlInstance 'NODE1' -SourcePath $Src)
				$r.Count | Should -Be 2
				$r.PartnerServer | Should -Be @('NODE2', 'NODE3')
				$drive = $Src.Substring(0, 1)
				$r[0].TargetPath | Should -Be ("\\NODE2\$drive`$" + $Src.Substring(2))
				$r.Status | Should -Be @('Copied', 'Copied')
			}
		}

		It 'liest nur fremde Replikate und uebergibt den AG-Namen escaped' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:srcPath } {
				param ($Src)
				Copy-sqmBackupToAgPeer -SqlInstance 'NODE1' -SourcePath $Src -AvailabilityGroupName "AG'1" | Out-Null
				Should -Invoke Invoke-DbaQuery -Times 1 -ParameterFilter {
					$Query -like '*is_local = 0*' -and $Query -like "*ag.name = N'AG''1'*"
				}
			}
		}

		It 'ruft robocopy mit /XO, ohne /MIR und /PURGE und mit dem Filter auf' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:srcPath } {
				param ($Src)
				Copy-sqmBackupToAgPeer -SqlInstance 'NODE1' -SourcePath $Src -Filter '*_anonym*.bak' | Out-Null
				$a = @($script:roboCalls[0])
				$a[0] | Should -Be $Src
				$a | Should -Contain '*_anonym*.bak'
				$a | Should -Contain '/XO'
				$a | Should -Not -Contain '/MIR'
				$a | Should -Not -Contain '/PURGE'
			}
		}

		It 'haengt mit -Recurse /E an und ohne -Recurse nicht (Ola-Unterordner)' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:srcPath } {
				param ($Src)
				Copy-sqmBackupToAgPeer -SqlInstance 'NODE1' -SourcePath $Src | Out-Null
				@($script:roboCalls[0]) | Should -Not -Contain '/E'
				$script:roboCalls.Clear()
				Copy-sqmBackupToAgPeer -SqlInstance 'NODE1' -SourcePath $Src -Recurse | Out-Null
				@($script:roboCalls[0]) | Should -Contain '/E'
				@($script:roboCalls[0]) | Should -Not -Contain '/MIR'
			}
		}

		It 'meldet UpToDate, wenn robocopy nichts kopiert hat (Exitcode 0)' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:srcPath } {
				param ($Src)
				Mock Invoke-sqmRobocopy { [PSCustomObject]@{ ExitCode = 0; Output = @() } }
				$r = @(Copy-sqmBackupToAgPeer -SqlInstance 'NODE1' -SourcePath $Src)
				$r.Status | Should -Be @('UpToDate', 'UpToDate')
			}
		}

		It 'wertet Exitcode 3 (kopiert, Extras vorhanden) als Erfolg' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:srcPath } {
				param ($Src)
				Mock Invoke-sqmRobocopy { [PSCustomObject]@{ ExitCode = 3; Output = @() } }
				$r = @(Copy-sqmBackupToAgPeer -SqlInstance 'NODE1' -SourcePath $Src)
				$r.Status | Should -Be @('Copied', 'Copied')
			}
		}

		It 'kopiert nichts mit -WhatIf' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:srcPath } {
				param ($Src)
				$r = @(Copy-sqmBackupToAgPeer -SqlInstance 'NODE1' -SourcePath $Src -WhatIf)
				$r.Status | Should -Be @('WhatIf', 'WhatIf')
				Should -Invoke Invoke-sqmRobocopy -Times 0
			}
		}

		It 'macht bei einem fehlgeschlagenen Partner mit den anderen weiter und wirft mit -EnableException erst danach' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:srcPath } {
				param ($Src)
				Mock Invoke-sqmRobocopy {
					$script:roboCalls.Add($Arguments)
					if ($Arguments[1] -like '\\NODE2\*') { [PSCustomObject]@{ ExitCode = 16; Output = @('Zugriff verweigert') } }
					else { [PSCustomObject]@{ ExitCode = 1; Output = @() } }
				}
				{ Copy-sqmBackupToAgPeer -SqlInstance 'NODE1' -SourcePath $Src -EnableException } | Should -Throw -ExpectedMessage '*NODE2*'
				$script:roboCalls.Count | Should -Be 2
			}
		}

		It 'liefert ohne -EnableException Failed mit Meldung statt zu werfen' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:srcPath } {
				param ($Src)
				Mock Invoke-sqmRobocopy { [PSCustomObject]@{ ExitCode = 8; Output = @('Fehler 5') } }
				$r = @(Copy-sqmBackupToAgPeer -SqlInstance 'NODE1' -SourcePath $Src -ErrorAction SilentlyContinue)
				$r.Status | Should -Be @('Failed', 'Failed')
				$r[0].Message | Should -BeLike '*Exitcode 8*'
			}
		}
	}

	Context 'Eingabepruefung' {
		BeforeEach {
			InModuleScope sqmSQLTool {
				$script:dbatoolsAvailable = $true
				Mock Invoke-sqmLogging { }
				Mock Invoke-sqmRobocopy { [PSCustomObject]@{ ExitCode = 1; Output = @() } }
			}
		}

		It 'lehnt einen UNC-Quellpfad ab' {
			InModuleScope sqmSQLTool {
				{ Copy-sqmBackupToAgPeer -SourcePath '\\srv\share\bak' -PartnerServer 'N2' -EnableException } | Should -Throw -ExpectedMessage '*lokaler Pfad*'
			}
		}

		It 'bricht ab, wenn das Quellverzeichnis fehlt' {
			InModuleScope sqmSQLTool {
				{ Copy-sqmBackupToAgPeer -SourcePath 'Z:\gibt\es\nicht' -PartnerServer 'N2' -EnableException } | Should -Throw -ExpectedMessage '*existiert nicht*'
				Should -Invoke Invoke-sqmRobocopy -Times 0
			}
		}

		It 'bricht ab, wenn die Instanz keine Partner-Replikate hat' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:srcPath } {
				param ($Src)
				Mock Invoke-DbaQuery { @() }
				{ Copy-sqmBackupToAgPeer -SqlInstance 'NODE1' -SourcePath $Src -EnableException } | Should -Throw -ExpectedMessage '*Keine Partner-Replikate*'
				Should -Invoke Invoke-sqmRobocopy -Times 0
			}
		}

		It 'nimmt -PartnerServer ohne AG-Abfrage' {
			InModuleScope sqmSQLTool -Parameters @{ Src = $script:srcPath } {
				param ($Src)
				Mock Invoke-DbaQuery { throw 'darf nicht aufgerufen werden' }
				$r = @(Copy-sqmBackupToAgPeer -SourcePath $Src -PartnerServer 'N2')
				$r.PartnerServer | Should -Be 'N2'
				Should -Invoke Invoke-DbaQuery -Times 0
			}
		}
	}
}
