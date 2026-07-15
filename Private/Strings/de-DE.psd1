@{
    # ── Allgemein ──────────────────────────────────────────────────────────────
    'Error_dbatoolsNotFound'        = 'dbatools-Modul nicht gefunden.'
    'Error_Generic'                 = 'Fehler in {0}: {1}'

    # ── Get-sqmWaitStatistics ──────────────────────────────────────────────────
    'WaitStats_Starting'            = 'Starte {0} auf {1} (TopN={2}, IncludeIdle={3})'
    'WaitStats_NoData'              = 'Keine Wait Statistics gelesen.'
    'WaitStats_SnapshotCreated'     = 'Snapshot erstellt: {0} Wait Types.'
    'WaitStats_Saved'               = 'Wait Statistics gespeichert: {0}'
    'WaitStats_Completed'           = '{0} abgeschlossen: {1} Wait Types, Total {2} Sek.'

    'WaitRec_PAGEIOLATCH_SH'        = 'Disk I/O Engpass - Storage Performance pruefen, fehlende Indizes analysieren.'
    'WaitRec_PAGEIOLATCH_EX'        = 'Disk I/O Engpass beim Schreiben - Storage und Index-Fragmentierung pruefen.'
    'WaitRec_PAGEIOLATCH_UP'        = 'Disk I/O beim Aktualisieren - Storage Performance pruefen.'
    'WaitRec_WRITELOG'              = 'Log-I/O Engpass - schnelleres Storage fuer Log-Dateien, kein RAID5.'
    'WaitRec_IO_COMPLETION'         = 'Allgemeine I/O-Verzoegerungen - Storage Performance pruefen.'
    'WaitRec_ASYNC_IO_COMPLETION'   = 'Asynchrone I/O Verzoegerung - Backup/Restore/DBCC auf langsamem Storage.'
    'WaitRec_LCK_M_X'              = 'Exclusive Lock-Waits - Transaktionsdesign, Index-Abdeckung, Isolation Level pruefen.'
    'WaitRec_LCK_M_S'              = 'Shared Lock-Waits - Read Committed Snapshot (RCSI) erwaegen.'
    'WaitRec_LCK_M_U'              = 'Update Lock-Waits - Abfragen optimieren, Index-Abdeckung verbessern.'
    'WaitRec_LCK_M_IX'             = 'Intent Exclusive Lock-Waits - Blocking analysieren, Indizes optimieren.'
    'WaitRec_LCK_M_IS'             = 'Intent Shared Lock-Waits - Transaktionsdauer reduzieren.'
    'WaitRec_CXPACKET'             = 'Parallelismus-Waits - MAXDOP und Cost Threshold for Parallelism anpassen.'
    'WaitRec_CXCONSUMER'           = 'Parallele Consumer warten - MAXDOP Einstellung pruefen.'
    'WaitRec_RESOURCE_SEMAPHORE'   = 'Memory Grant Wartezeit - Abfragen mit zu grossem Memory Grant, Index-Fragmentierung.'
    'WaitRec_RES_SEM_COMPILE'      = 'Kompilierungs-Speichermangel - zu viele gleichzeitige Kompilierungen.'
    'WaitRec_CMEMTHREAD'           = 'Speicher-Contention - evtl. NUMA-Ungleichgewicht oder max server memory zu niedrig.'
    'WaitRec_SOS_SCHEDULER_YIELD'  = 'CPU-Druck - langlaufende Abfragen optimieren, CPU-Ressourcen erhoehen.'
    'WaitRec_THREADPOOL'           = 'Worker Thread Mangel - max worker threads oder Hardware-Kapazitaet pruefen.'
    'WaitRec_PAGELATCH_EX'         = 'Page-Latch Contention - oft tempdb-Engpass oder Hot Pages (GUID-basierte Indizes).'
    'WaitRec_PAGELATCH_SH'         = 'Shared Page Latch Contention - tempdb-Dateien erhoehen (8 empfohlen).'
    'WaitRec_PAGELATCH_UP'         = 'Update Page Latch - Last Page Insert Contention, Sequential Keys vermeiden.'
    'WaitRec_LATCH_EX'             = 'Interne Latch-Contention - dbatools Get-DbaLatch fuer Details verwenden.'
    'WaitRec_LATCH_SH'             = 'Interne Shared Latch - Statistiken und Plandaten koennen betroffen sein.'
    'WaitRec_DBMIRROR_EVENTS_QUEUE'= 'Database Mirroring Queue - Netzwerklatenz zwischen Partnern pruefen.'
    'WaitRec_DBMIRRORING_CMD'      = 'Mirroring-Synchronisation - Netzwerkdurchsatz pruefen.'
    'WaitRec_ASYNC_NETWORK_IO'     = 'Client verarbeitet Daten zu langsam - Result Sets verkleinern, Paginierung erwaegen.'

    # ── Get-sqmPerfCounters ────────────────────────────────────────────────────
    'PerfCounters_Starting'         = 'Starte {0} auf {1}'
    'PerfCounters_Completed'        = '{0}: {1} Counter gelesen, {2} Warnungen.'
    'PerfCounters_Saved'            = 'Counter-Report gespeichert: {0}'
    'PerfInterp_PLE_Critical'       = 'CRITICAL: PLE < 300 Sek - Speichermangel oder Cache Churn'
    'PerfInterp_PLE_Warning'        = 'WARNING: PLE < 600 Sek - Speicher beobachten'
    'PerfInterp_MemGrants'          = 'WARNING: Queries warten auf Memory Grant - Index-/Query-Optimierung erforderlich'
    'PerfInterp_Blocking_Critical'  = 'CRITICAL: Blocking aktiv'
    'PerfInterp_Blocking_Warning'   = 'WARNING: Blocking aktiv'
    'PerfInterp_Deadlocks'          = 'WARNING: Deadlocks aufgetreten - Extended Events Deadlock-Trace auswerten'
    'PerfInterp_LazyWrites'         = 'WARNING: Hohe Lazy Write Rate - Speicher pruefen'
    'PerfInterp_ReCompilations'     = 'WARNING: Hohe Re-Kompilierungsrate - SET-Optionen und Schema-Aenderungen pruefen'

    # ── Invoke-sqmPatchAnalysis ────────────────────────────────────────────────
    'PatchAnalysis_Starting'        = 'Starte {0} fuer {1} Instanz(en)'
    'PatchAnalysis_InstanceResult'  = '[{0}] {1} {2} - {3} ({4} builds behind)'
    'PatchAnalysis_Saved'           = 'Patch-Analyse gespeichert: {0}'
    'PatchAnalysis_Completed'       = '{0} abgeschlossen: {1} Instanz(en), {2} Critical, {3} zu aktualisieren.'
    'PatchAnalysis_InstanceError'   = '[{0}] Fehler: {1}'
    'PatchRec_UpToDate'             = 'Aktuell - kein Patch erforderlich.'
    'PatchRec_Outdated'             = "{0} Build(s) hinter aktuellem Stand. Naechstes Update: {1}. Empfehlung: auf {2} ({3}) aktualisieren."
    'PatchRec_UnknownVersion'       = 'Keine Referenz fuer Major Version {0} vorhanden.'

    # ── Invoke-sqmFailover ─────────────────────────────────────────────────────
    'Failover_Starting'             = "Starte {0}: AG='{1}', Primary='{2}', Target='{3}'"
    'Failover_AgNotFound'           = "AG '{0}' nicht gefunden oder Instanz '{1}' ist kein Mitglied."
    'Failover_NotPrimary'           = "Instanz '{0}' ist nicht Primary (aktuell: {1}). Failover muss von der Primary aus initiiert werden."
    'Failover_NoSecondaries'        = "Keine Sekundaer-Replikate fuer AG '{0}' gefunden."
    'Failover_TargetNotFound'       = "Ziel-Replikat '{0}' nicht gefunden oder nicht Sekundaer."
    'Failover_NoSuitableTarget'     = 'Kein geeignetes Ziel-Replikat gefunden (SYNCHRONIZED benoetigt).'
    'Failover_RedoQueueLimit'       = "Redo-Queue auf '{0}' betraegt {1} MB (Limit: {2} MB). Failover abgebrochen."
    'Failover_PreCheckPassed'       = "Pre-Checks bestanden. Ziel: '{0}', SyncState: {1}, Redo-Queue: {2} MB"
    'Failover_WhatIf'               = "WhatIf: Failover wuerde auf '{0}' ausgefuehrt werden."
    'Failover_Executing'            = "Starte Failover auf '{0}'..."
    'Failover_Waiting'              = 'Failover-Befehl ausgefuehrt. Warte {0} Sek...'
    'Failover_Success'              = "Failover erfolgreich. '{0}' ist nun Primary. SyncHealth: {1}"
    'Failover_PostCheckFailed'      = 'Failover ausgefuehrt, aber Post-Check konnte Rolle nicht bestaetigen. Bitte manuell pruefen.'
    'Failover_PostCheckError'       = 'Failover ausgefuehrt, Post-Check fehlgeschlagen: {0}'
    'Failover_Completed'            = '{0} abgeschlossen in {1} Sek.'

    # ── Get-sqmConnectionStats ────────────────────────────────────────────────
    'ConnStats_Starting'            = 'Starte {0} auf {1} (GroupBy={2})'
    'ConnStats_Summary'             = '{0}: {1} Verbindungen ({2}% von max {3}), {4} aktiv, {5} blockiert.'
    'ConnStats_Saved'               = 'Connection-Report gespeichert: {0}'

    # ── Get-sqmOrphanedFiles ──────────────────────────────────────────────────
    'Orphaned_RemoteWarning'        = 'Remote-Instanz erkannt. Dateisystemzugriff erfolgt von diesem Computer aus. Gib SearchPath als UNC-Pfad an falls die Pfade nicht direkt erreichbar sind.'
    'Orphaned_Starting'             = 'Starte {0} auf {1}'
    'Orphaned_DirectoriesCount'     = '{0} Verzeichnis(se) werden durchsucht.'
    'Orphaned_DirNotReachable'      = 'Verzeichnis nicht erreichbar: {0}'
    'Orphaned_Completed'            = '{0}: {1} Dateien gescannt, {2} verwaiste Dateien gefunden.'
    'Orphaned_NoneFound'            = 'Keine verwaisten Datenbankdateien gefunden.'

    # ── Invoke-sqmPerfBaseline ────────────────────────────────────────────────
    'Baseline_Starting'             = 'Starte {0} auf {1}, Action={2}'
    'Baseline_NoFiles'              = 'Keine Baseline-Dateien gefunden in: {0}'
    'Baseline_Saved'                = 'Baseline gespeichert: {0} ({1} Waits, {2} Counters)'
    'Baseline_NotEnoughFiles'       = 'Nicht genuegend Baseline-Dateien fuer Vergleich. Mindestens 2 Baselines benoetigt.'
    'Baseline_Comparing'            = "Vergleich: '{0}' vs '{1}'"

    # ── Invoke-sqmRestoreTest (Nachweis) ──────────────────────────────────────
    'RestoreTest_Title'             = 'Nachweis Restore-Test'
    'RestoreTest_ReportHeadline'    = 'sqmSQLTool - Nachweis Restore-Test'
    'RestoreTest_Instance'          = 'Instanz'
    'RestoreTest_Created'           = 'Erstellt'

    'RestoreTest_SectionResult'     = 'Ergebnis'
    'RestoreTest_Status'            = 'Status'
    'RestoreTest_Successful'        = 'ERFOLGREICH'
    'RestoreTest_Failed'            = 'FEHLGESCHLAGEN'
    'RestoreTest_SourceDatabase'    = 'Quelldatenbank'
    'RestoreTest_TestDatabase'      = 'Testdatenbank'

    'RestoreTest_SectionMetrics'    = 'Kennzahlen'
    'RestoreTest_DataVolume'        = 'Datenmenge (Backup)'
    'RestoreTest_PhysicallyRead'    = 'davon physisch gelesen'
    'RestoreTest_Duration'          = 'Dauer'
    'RestoreTest_Throughput'        = 'Datendurchsatz'
    'RestoreTest_Compressed'        = 'komprimiert gelesen'
    'RestoreTest_Uncompressed'      = 'unkomprimiert'
    'RestoreTest_SizeUnknown'       = 'unbekannt'
    'RestoreTest_NotDeterminable'   = 'nicht ermittelbar'

    'RestoreTest_SectionDetails'    = 'Details'
    'RestoreTest_Start'             = 'Start'
    'RestoreTest_End'               = 'Ende'
    'RestoreTest_BackupFiles'       = 'Backupdateien'
    'RestoreTest_RestoredFiles'     = 'Wiederhergestellte Dateien'
    'RestoreTest_CleanedUp'         = 'Aufgeraeumt'
    'RestoreTest_CleanedUpYes'      = 'Ja - Test-Datenbank entfernt'
    'RestoreTest_CleanedUpNo'       = 'Nein - Test-Datenbank bleibt erhalten'
    'RestoreTest_Retention'         = 'Aufbewahrung Nachweise'
    'RestoreTest_RetentionMonths'   = '{0} Monate'
    'RestoreTest_RetentionForever'  = 'unbegrenzt'
    'RestoreTest_ResolvedVia'       = 'Backup ermittelt ueber'
    'RestoreTest_SourceHistory'     = 'msdb-Sicherungshistorie'
    'RestoreTest_SourceScan'        = 'Verzeichnis-Scan'
    'RestoreTest_SourceParameter'   = 'ausdruecklich angegeben'
    'RestoreTest_BackupSource'      = 'Backupquelle'
    'RestoreTest_ThroughputNote'    = 'Der Datendurchsatz bezieht sich auf die logische Datenmenge (BackupSize) und wird als Wall-Clock-Zeit ueber den gesamten Restore gemessen.'
}
