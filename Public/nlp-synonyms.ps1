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
	'blockiert'         = @('Get-sqmBlockingReport', 'Get-sqmBlockingHistory')
	'blockierung'       = @('Get-sqmBlockingReport', 'Get-sqmBlockingHistory')
	'vorfall'           = @('Get-sqmBlockingHistory')
	'historie'          = @('Get-sqmBlockingHistory')
	'deadlock'          = @('Get-sqmDeadlockReport')
	'umschalten'        = @('Invoke-sqmFailover')
	'ausfallsicherheit' = @('Get-sqmAlwaysOnHealthReport', 'Invoke-sqmFailover')
	'passwort'          = @('New-sqmRandomSaPassword', 'Set-sqmSqlPolicyState')
	'zertifikat'        = @('Get-sqmCertificateReport', 'Install-sqmCertificate', 'New-sqmCertificateRequest')
	'fragmentiert'      = @('Get-sqmIndexFragmentation')
	'inventar'          = @('Invoke-sqmInstanceInventory')
	'wer ist drin'      = @('Get-sqmSysadminAccounts', 'Get-sqmLoginSettings')
	'gesundheit'        = @('Get-sqmDatabaseHealth', 'Get-sqmSQLInstanceCheck')
	'wer ist aktiv'     = @('Get-sqmWhoIsActive', 'Show-sqmWhoIsActiveMonitor')
	'aktive sessions'   = @('Get-sqmWhoIsActive', 'Show-sqmWhoIsActiveMonitor')
	'whoisactive'       = @('Get-sqmWhoIsActive', 'Show-sqmWhoIsActiveMonitor')
	'zurueckschwenken'  = @('Invoke-sqmPreferredPrimaryCheck', 'New-sqmPreferredPrimaryJob')
	'zurückschwenken'   = @('Invoke-sqmPreferredPrimaryCheck', 'New-sqmPreferredPrimaryJob')
	'bevorzugter knoten' = @('Invoke-sqmPreferredPrimaryCheck', 'New-sqmPreferredPrimaryJob')
	'falscher knoten'   = @('Invoke-sqmPreferredPrimaryCheck', 'Get-sqmAlwaysOnHealthReport')
	'patchwochenende'   = @('Invoke-sqmPreferredPrimaryCheck', 'Get-sqmAlwaysOnFailoverHistory')
	'wer ruft auf'      = @('Find-sqmAgentJobReference', 'Find-sqmDatabaseObject')
	'ruft prozedur auf' = @('Find-sqmAgentJobReference')
	'welcher job'       = @('Find-sqmAgentJobReference', 'Get-sqmAgentJobScheduleReport')
	'wird das benutzt'  = @('Find-sqmAgentJobReference', 'Find-sqmDatabaseObject')
	'prozedur loeschen' = @('Find-sqmAgentJobReference')
	'prozedur löschen'  = @('Find-sqmAgentJobReference')
	'datenbank abschalten' = @('Find-sqmAgentJobReference', 'Get-sqmLinkedServerUsage')
	'wer leert die tabelle' = @('Find-sqmAgentJobReference')
	'ssis umziehen'     = @('Invoke-sqmSsisCatalogMigration')
	'ssisdb umziehen'   = @('Invoke-sqmSsisCatalogMigration')
	'katalog umziehen'  = @('Invoke-sqmSsisCatalogMigration')
	'ssis auf neuen server' = @('Invoke-sqmSsisCatalogMigration')
	'ssis upgrade'      = @('Invoke-sqmSsisCatalogMigration', 'Test-sqmSSISPackageCompatibility')
	'pakete laufen nicht mehr' = @('Invoke-sqmSsisCatalogMigration', 'Find-sqmAgentJobReference')
	'hauptschlüssel'    = @('Invoke-sqmSsisCatalogMigration')
	'master key'        = @('Invoke-sqmSsisCatalogMigration')
}
