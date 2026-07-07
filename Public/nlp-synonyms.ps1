# =============================================================================
# nlp-synonyms.ps1 - Umgangssprachliche Stichworte -> Funktionsnamen.
# Boost-Tabelle fuer die Klartextsuche in Show-sqmToolGui: Wer nicht weiss, wie
# eine Funktion heisst, tippt z.B. "Datenbank restoren" oder "Platte ist voll"
# ins Suchfeld statt eines Funktionsnamens/Wildcards. Ohne Eintrag hier greift
# trotzdem die Volltextsuche ueber Synopsis/Description/Parameter - diese Tabelle
# faengt nur Formulierungen ab, die in der Hilfe nicht woertlich vorkommen
# (z.B. Konjugationen wie "restoren" statt "Restore").
#
# Bei neuen Funktionen oder haeufig falsch gesuchten Begriffen hier ergaenzen.
# Format: 'stichwort oder phrase' = @('Funktionsname1', 'Funktionsname2', ...)
# =============================================================================
$sqmNlpSynonyms = @{
	'restoren'          = @('Invoke-sqmRestoreDatabase')
	'wiederherstellen'  = @('Invoke-sqmRestoreDatabase')
	'zurücksichern'     = @('Invoke-sqmRestoreDatabase')
	'zuruecksichern'    = @('Invoke-sqmRestoreDatabase')
	'sichern'           = @('Invoke-sqmUserDatabaseBackup', 'New-sqmOlaUsrDbBackupJob', 'New-sqmOlaSysDbBackupJob', 'New-sqmBackupMaintenanceJob')
	'backup machen'     = @('Invoke-sqmUserDatabaseBackup')
	'platte voll'       = @('Get-sqmDiskSpaceReport')
	'speicherplatz'     = @('Get-sqmDiskSpaceReport')
	'festplatte'        = @('Get-sqmDiskSpaceReport', 'Get-sqmDiskInfoByDriveLetter', 'Get-sqmDiskPartitionMap')
	'langsam'           = @('Get-sqmLongRunningQueries', 'Get-sqmWaitStatistics', 'Invoke-sqmPerfBaseline')
	'hängt'             = @('Get-sqmBlockingReport', 'Get-sqmLongRunningQueries')
	'haengt'            = @('Get-sqmBlockingReport', 'Get-sqmLongRunningQueries')
	'blockiert'         = @('Get-sqmBlockingReport')
	'blockierung'       = @('Get-sqmBlockingReport')
	'deadlock'          = @('Get-sqmDeadlockReport')
	'umschalten'        = @('Invoke-sqmFailover')
	'ausfallsicherheit' = @('Get-sqmAlwaysOnHealthReport', 'Invoke-sqmFailover')
	'passwort'          = @('New-sqmRandomSaPassword', 'Set-sqmSqlPolicyState')
	'zertifikat'        = @('Get-sqmCertificateReport', 'Install-sqmCertificate', 'New-sqmCertificateRequest')
	'fragmentiert'      = @('Get-sqmIndexFragmentation')
	'inventar'          = @('Invoke-sqmInstanceInventory')
	'wer ist drin'      = @('Get-sqmSysadminAccounts', 'Get-sqmLoginSettings')
	'gesundheit'        = @('Get-sqmDatabaseHealth', 'Get-sqmSQLInstanceCheck')
}
