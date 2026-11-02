#Requires -Modules Pester
<#
.SYNOPSIS
    Unit Tests fuer die Restore-Ketten-Ermittlung ueber alle AG-Replikate (Invoke-sqmRestoreDatabase ohne -BackupFile).

.DESCRIPTION
    Historie wird gemockt. Geprueft: COPY_ONLY-Full vom Secondary wird gefunden, Pfade fremder
    Replikate werden zum Admin-Share, Logs aus beiden Historien ergeben eine lueckenlose Kette,
    dasselbe Log in zwei Historien wird nur einmal verwendet, eine Luecke beendet die Kette,
    ohne AG wird nur die Einstiegs-Instanz befragt.
#>

BeforeAll {
	. "$PSScriptRoot\..\..\..\tests\TestHelpers.ps1"
	Import-sqmTestModule
}

AfterAll {
	if (Get-Module sqmSQLTool) { Remove-Module sqmSQLTool -Force }
}

Describe 'Get-sqmRestoreChainFromReplica' {

	BeforeAll {
		function global:New-Row($Type, $Start, $Path, $First, $Last, $Checkpoint = 0, $DiffBase = 0, $CopyOnly = $false)
		{
			[PSCustomObject]@{
				Type = $Type; Start = [datetime]$Start; Path = @($Path); FirstLsn = [decimal]$First; LastLsn = [decimal]$Last
				CheckpointLsn = [decimal]$Checkpoint; DatabaseBackupLsn = [decimal]$DiffBase; IsCopyOnly = $CopyOnly
			}
		}
	}

	Context 'AG, Full und Logs auf dem Secondary' {
		It 'baut die Kette ueber beide Replikate und schreibt fremde Pfade auf den Admin-Share um' {
			InModuleScope sqmSQLTool {
				Mock Invoke-sqmLogging { }
				Mock Test-Path { $true }
				Mock Get-sqmDatabaseAgMembership { [PSCustomObject]@{ HadrEnabled = $true; IsAgDatabase = $true; AvailabilityGroupName = 'AG1'; PrimaryReplica = 'SQL01' } }
				Mock Get-DbaAgReplica { @([PSCustomObject]@{ Name = 'SQL01' }, [PSCustomObject]@{ Name = 'SQL02' }) }
				Mock Get-DbaDbBackupHistory {
					if ("$SqlInstance" -eq 'SQL01')
					{
						@(
							(New-Row 'Full' '2026-11-01 01:00' 'G:\bak\old_full.bak' 100 200 200)
							(New-Row 'Log' '2026-11-02 01:30' 'G:\bak\l2.trn' 300 400)
						)
					}
					else
					{
						@(
							(New-Row 'Full' '2026-11-02 00:00' 'H:\bak\new_full.bak' 250 300 300 0 $true)
							(New-Row 'Log' '2026-11-02 01:00' 'H:\bak\l1.trn' 280 350)
							(New-Row 'Log' '2026-11-02 01:30' 'H:\bak\l2.trn' 300 400)
							(New-Row 'Log' '2026-11-02 02:00' 'H:\bak\l3.trn' 400 500)
						)
					}
				}

				$r = Get-sqmRestoreChainFromReplica -SqlInstance 'SQL01' -Database 'Arena'
				$r.WorkInstance | Should -Be 'SQL01'
				$r.Files | Should -Be @('\\SQL02\H$\bak\new_full.bak', '\\SQL02\H$\bak\l1.trn', 'G:\bak\l2.trn', '\\SQL02\H$\bak\l3.trn')
			}
		}

		It 'beendet die Kette an einer Log-Luecke' {
			InModuleScope sqmSQLTool {
				Mock Invoke-sqmLogging { }
				Mock Test-Path { $true }
				Mock Get-sqmDatabaseAgMembership { [PSCustomObject]@{ HadrEnabled = $true; IsAgDatabase = $true; AvailabilityGroupName = 'AG1'; PrimaryReplica = 'SQL01' } }
				Mock Get-DbaAgReplica { @([PSCustomObject]@{ Name = 'SQL01' }, [PSCustomObject]@{ Name = 'SQL02' }) }
				Mock Get-DbaDbBackupHistory {
					if ("$SqlInstance" -eq 'SQL01') { @((New-Row 'Full' '2026-11-02 00:00' 'G:\f.bak' 100 200 200), (New-Row 'Log' '2026-11-02 01:00' 'G:\l1.trn' 150 300)) }
					else { @((New-Row 'Log' '2026-11-02 03:00' 'H:\l3.trn' 500 600)) }
				}

				$r = Get-sqmRestoreChainFromReplica -SqlInstance 'SQL01' -Database 'Arena'
				$r.Files | Should -Be @('G:\f.bak', 'G:\l1.trn')
			}
		}

		It 'nimmt das Diff nur, wenn es auf dem gewaehlten Full basiert' {
			InModuleScope sqmSQLTool {
				Mock Invoke-sqmLogging { }
				Mock Test-Path { $true }
				Mock Get-sqmDatabaseAgMembership { [PSCustomObject]@{ HadrEnabled = $true; IsAgDatabase = $true; AvailabilityGroupName = 'AG1'; PrimaryReplica = 'SQL01' } }
				Mock Get-DbaAgReplica { @([PSCustomObject]@{ Name = 'SQL01' }, [PSCustomObject]@{ Name = 'SQL02' }) }
				Mock Get-DbaDbBackupHistory {
					if ("$SqlInstance" -eq 'SQL01') { @((New-Row 'Full' '2026-11-01 00:00' 'G:\f.bak' 100 200 200), (New-Row 'Differential' '2026-11-02 01:00' 'G:\d.bak' 210 300 300 200)) }
					else { @((New-Row 'Full' '2026-11-02 00:00' 'H:\cf.bak' 250 260 260 0 $true)) }
				}

				$r = Get-sqmRestoreChainFromReplica -SqlInstance 'SQL01' -Database 'Arena'
				$r.Files | Should -Be @('\\SQL02\H$\cf.bak')
			}
		}
	}

	Context 'Keine AG' {
		It 'fragt nur die Einstiegs-Instanz' {
			InModuleScope sqmSQLTool {
				Mock Invoke-sqmLogging { }
				Mock Get-sqmDatabaseAgMembership { [PSCustomObject]@{ HadrEnabled = $false; IsAgDatabase = $false; AvailabilityGroupName = $null; PrimaryReplica = $null } }
				Mock Get-DbaDbBackupHistory { @((New-Row 'Full' '2026-11-02 00:00' 'D:\f.bak' 100 200 200)) }

				$r = Get-sqmRestoreChainFromReplica -SqlInstance 'SQL01' -Database 'Arena'
				$r.Files | Should -Be @('D:\f.bak')
				Should -Invoke Get-DbaDbBackupHistory -Times 1 -Exactly
			}
		}

		It 'wirft ohne Historie' {
			InModuleScope sqmSQLTool {
				Mock Invoke-sqmLogging { }
				Mock Get-sqmDatabaseAgMembership { [PSCustomObject]@{ HadrEnabled = $false; IsAgDatabase = $false; AvailabilityGroupName = $null; PrimaryReplica = $null } }
				Mock Get-DbaDbBackupHistory { @() }

				{ Get-sqmRestoreChainFromReplica -SqlInstance 'SQL01' -Database 'Arena' } | Should -Throw '*Keine Backup-Historie*'
			}
		}
	}
}
