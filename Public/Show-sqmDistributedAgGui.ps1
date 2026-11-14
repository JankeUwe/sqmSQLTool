function Show-sqmDistributedAgGui
{
<#
.SYNOPSIS
    Assistent (GUI) zur Migration eines AlwaysOn-AG auf einen neuen AlwaysOn-Cluster per Distributed AG.

.DESCRIPTION
    Fuehrt Schritt fuer Schritt durch die Migration:
    Verbinden, Konfigurieren, Vorabpruefung (Test-sqmDistributedAgMigrationPrerequisite), Zusammenfassung mit
    Trockenlauf, Ausfuehrung (New-sqmDistributedAvailabilityGroup, Add-sqmDatabaseToDistributedAg),
    Synchronisation ueberwachen, Listener-Umzug (Invoke-sqmListenerMigrationPrep, Complete-sqmListenerMigration),
    Failover (Invoke-sqmDistributedFailover) und Abschluss mit Bericht.

    Die Oberflaeche ruft ausschliesslich die vorhandenen Funktionen auf. Alle Aktionen laufen in einem
    Hintergrund-Runspace, die Oberflaeche bleibt bedienbar. Der Fortschritt wird in einer Zustandsdatei
    (ohne Kennwoerter) gespeichert, eine unterbrochene Migration laesst sich ueber "Fortsetzen" wieder aufnehmen.
    Pro Migration kann nur ein Assistent gleichzeitig arbeiten (Sperrdatei).

    Modi: Neue Migration, Fortsetzen, Betrieb (Health, Failover, Rollback einer bestehenden Distributed AG).

.PARAMETER Language
    'de' oder 'en'. Standard: Sprache der Modulkonfiguration, sonst 'de'. Umschalten ist im Fenster moeglich.

.PARAMETER StatePath
    Ablageordner fuer Zustands- und Sperrdateien. Standard: <Output>\DistributedAgMigration.

.EXAMPLE
    Show-sqmDistributedAgGui

.EXAMPLE
    Show-sqmDistributedAgGui -Language en

.NOTES
    Benoetigt Windows PowerShell 5.1 mit WinForms und dbatools. Fuer die Migration werden sysadmin-Rechte
    auf beiden Seiten benoetigt. Der Listener-Umzug erfordert ein Cluster-/AD-Team auf dem Ziel-Cluster.
#>
	[CmdletBinding()]
	param (
		[ValidateSet('de', 'en')]
		[string]$Language,
		[string]$StatePath,
		[Parameter(DontShow)]
		[scriptblock]$OnShown
	)

	$onShownHook = $OnShown
	Add-Type -AssemblyName System.Windows.Forms
	Add-Type -AssemblyName System.Drawing
	try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { Write-Verbose $_.Exception.Message }

	if (-not $Language)
	{
		$Language = 'de'
		try { if ($script:sqmModuleConfig -and "$($script:sqmModuleConfig['Language'])" -like 'en*') { $Language = 'en' } } catch { Write-Verbose $_.Exception.Message }
	}

	# =====================================================================
	# Texte (de / en)
	# =====================================================================
	$Tx = @{ de = @{ }; en = @{ } }
	$def = { param ($k, $de, $en) $Tx.de[$k] = $de; $Tx.en[$k] = $en }

	& $def 'title' 'Distributed AG Migrationsassistent' 'Distributed AG Migration Wizard'
	& $def 'back' '< Zurück' '< Back'
	& $def 'next' 'Weiter >' 'Next >'
	& $def 'cancel' 'Abbrechen' 'Cancel'
	& $def 'close' 'Schließen' 'Close'
	& $def 'start' 'Migration starten' 'Start migration'
	& $def 'showlog' 'Protokoll anzeigen' 'Show log'
	& $def 'hidelog' 'Protokoll ausblenden' 'Hide log'
	& $def 'savelog' 'Protokoll speichern' 'Save log'
	& $def 'ready' 'Bereit.' 'Ready.'
	& $def 'busy' 'Bitte warten ...' 'Please wait ...'

	& $def 's0' 'Willkommen' 'Welcome'
	& $def 's1' 'Verbindung' 'Connection'
	& $def 's2' 'Konfiguration' 'Configuration'
	& $def 's3' 'Vorabprüfung' 'Preflight checks'
	& $def 's4' 'Zusammenfassung' 'Summary'
	& $def 's5' 'Ausführung' 'Execution'
	& $def 's6' 'Synchronisation' 'Synchronization'
	& $def 's7' 'Listener-Umzug' 'Listener move'
	& $def 's8' 'Failover' 'Failover'
	& $def 's9' 'Abschluss' 'Finish'

	& $def 'h0' 'Willkommen' 'Welcome'
	& $def 'h0s' 'Dieser Assistent führt Sie sicher durch die Migration auf einen neuen AlwaysOn-Cluster.' 'This wizard guides you safely through the migration to a new AlwaysOn cluster.'
	& $def 'h1' 'Quelle und Ziel verbinden' 'Connect source and target'
	& $def 'h1s' 'Geben Sie die SQL-Instanz des bisherigen Clusters (Quelle) und des neuen Clusters (Ziel) an.' 'Enter the SQL instance of the current cluster (source) and the new cluster (target).'
	& $def 'h2' 'Distributed AG konfigurieren' 'Configure the Distributed AG'
	& $def 'h2s' 'Die Vorschläge stammen aus den verbundenen Servern. Ändern Sie nur, was nötig ist.' 'The suggestions come from the connected servers. Change only what is necessary.'
	& $def 'h3' 'Vorabprüfung' 'Preflight checks'
	& $def 'h3s' 'Es wird nur gelesen, nichts wird geändert. Fehler müssen behoben werden, Warnungen bestätigen Sie.' 'Read only, nothing is changed. Errors must be fixed, warnings must be acknowledged.'
	& $def 'h4' 'Zusammenfassung und Trockenlauf' 'Summary and dry run'
	& $def 'h4s' 'Prüfen Sie die geplanten Aktionen. Der Trockenlauf ändert nichts auf den Servern.' 'Review the planned actions. The dry run changes nothing on the servers.'
	& $def 'h5' 'Migration wird ausgeführt' 'Migration in progress'
	& $def 'h5s' 'Bitte schließen Sie das Fenster nicht. Jeder Schritt kann bei Fehlern wiederholt werden.' 'Please do not close the window. Every step can be repeated after an error.'
	& $def 'h6' 'Synchronisation überwachen' 'Monitor synchronization'
	& $def 'h6s' 'Die Datenbanken werden auf den neuen Cluster übertragen. Warten Sie, bis alle bereit sind.' 'The databases are being transferred to the new cluster. Wait until all are ready.'
	& $def 'h7' 'Listener-Umzug' 'Listener move'
	& $def 'h7s' 'Drei Phasen mit dem Cluster-/AD-Team. Reihenfolge und Wartezeit sind wichtig.' 'Three phases with the cluster/AD team. Order and waiting time matter.'
	& $def 'h8' 'Failover auf den neuen Cluster' 'Fail over to the new cluster'
	& $def 'h8s' 'Geplantes Failover ohne Datenverlust. Anwendungen verlieren kurz die Verbindung.' 'Planned failover without data loss. Applications briefly lose their connection.'
	& $def 'h9' 'Abschluss' 'Finish'
	& $def 'h9s' 'Zusammenfassung der Migration und empfohlene nächste Schritte.' 'Summary of the migration and recommended next steps.'

	# Seite 0
	& $def 'w_intro' "Eine Distributed Availability Group verbindet den bisherigen AlwaysOn-Cluster mit dem neuen. Die Daten werden im laufenden Betrieb übertragen. Erst beim Failover wechseln Anwendungen auf den neuen Cluster. Bis dahin können Sie jederzeit abbrechen." "A Distributed Availability Group connects the current AlwaysOn cluster with the new one. Data is transferred during normal operation. Applications only switch to the new cluster at failover. Until then you can stop at any time."
	& $def 'w_what' 'Was möchten Sie tun?' 'What do you want to do?'
	& $def 'w_new' 'Neue Migration starten' 'Start a new migration'
	& $def 'w_resume' 'Eine unterbrochene Migration fortsetzen' 'Resume an interrupted migration'
	& $def 'w_ops' 'Betrieb: Zustand prüfen, Failover oder Rollback einer bestehenden Distributed AG' 'Operations: check status, fail over or roll back an existing Distributed AG'
	& $def 'w_noresume' 'Keine gespeicherten Migrationen gefunden.' 'No saved migrations found.'
	& $def 'w_corrupt' '(Datei beschädigt)' '(file damaged)'
	& $def 'w_prereq' 'Sie benötigen: sysadmin auf beiden Seiten, einen vorbereiteten Ziel-Cluster mit leerer Ziel-AG, Netzverbindung zwischen den Clustern (Endpoint-Port) und dbatools.' 'You need: sysadmin on both sides, a prepared target cluster with an empty target AG, a network connection between the clusters (endpoint port) and dbatools.'
	& $def 'd_src' 'Quell-AG (alt)' 'Source AG (old)'
	& $def 'd_dag' 'Distributed AG' 'Distributed AG'
	& $def 'd_tgt' 'Ziel-AG (neu)' 'Target AG (new)'
	& $def 'd_fo' 'Failover' 'Failover'
	& $def 'd_clean' 'Aufräumen' 'Clean up'

	# Seite 1
	& $def 'c_src' 'Quelle (bisheriger Cluster)' 'Source (current cluster)'
	& $def 'c_tgt' 'Ziel (neuer Cluster)' 'Target (new cluster)'
	& $def 'c_inst' 'SQL-Instanz oder Listener' 'SQL instance or listener'
	& $def 'c_ag' 'Availability Group' 'Availability group'
	& $def 'c_dag' 'Distributed AG' 'Distributed AG'
	& $def 'c_auth' 'Anmeldung' 'Authentication'
	& $def 'c_win' 'Windows-Konto des aktuellen Benutzers' 'Windows account of the current user'
	& $def 'c_sql' 'SQL-Anmeldung' 'SQL login'
	& $def 'c_user' 'Benutzername' 'User name'
	& $def 'c_pwd' 'Kennwort' 'Password'
	& $def 'c_test' 'Verbindung testen und Gruppen laden' 'Test connection and load groups'
	& $def 'c_hint' 'Tipp: Verbinden Sie sich mit dem aktuellen Primary oder dem Listener. Das Kennwort wird nicht gespeichert und nicht protokolliert.' 'Tip: connect to the current primary or the listener. The password is neither saved nor logged.'
	& $def 'c_ok' 'Verbunden: {0} (SQL {1}), {2} Gruppe(n)' 'Connected: {0} (SQL {1}), {2} group(s)'
	& $def 'c_same' 'Quelle und Ziel sind dieselbe Instanz.' 'Source and target are the same instance.'
	& $def 'c_noag' 'Auf dieser Instanz wurde keine Availability Group gefunden.' 'No availability group was found on this instance.'
	& $def 'c_nohadr' 'Always On ist auf dieser Instanz nicht aktiviert.' 'Always On is not enabled on this instance.'
	& $def 'c_nosys' 'Das Konto ist auf dieser Instanz kein sysadmin.' 'The account is not sysadmin on this instance.'
	& $def 'c_notpri' 'Hinweis: {0} ist hier nicht PRIMARY. Verbinden Sie sich mit dem Primary.' 'Note: {0} is not PRIMARY here. Connect to the primary.'
	& $def 'c_pick' 'Bitte eine Gruppe auswählen.' 'Please select a group.'
	& $def 'c_loaded' 'Bitte zuerst die Verbindung testen.' 'Please test the connection first.'
	& $def 'c_nodag' 'Keine Distributed AG gefunden.' 'No Distributed AG found.'
	& $def 'c_locked' 'Diese Migration wird bereits bearbeitet von {0} auf {1} (seit {2}). Zwei Assistenten dürfen nicht gleichzeitig arbeiten.' 'This migration is already being processed by {0} on {1} (since {2}). Two wizards must not work at the same time.'

	# Seite 2
	& $def 'f_dagname' 'Name der Distributed AG' 'Name of the Distributed AG'
	& $def 'f_port' 'Endpoint-Port' 'Endpoint port'
	& $def 'f_srcfqdn' 'FQDN der Quelle (für LISTENER_URL)' 'FQDN of the source (for LISTENER_URL)'
	& $def 'f_tgtfqdn' 'FQDN des Ziels (für LISTENER_URL)' 'FQDN of the target (for LISTENER_URL)'
	& $def 'f_acct' 'SQL-Dienstkonto (optional, legt Login und CONNECT-Recht an)' 'SQL service account (optional, creates login and CONNECT permission)'
	& $def 'f_seed' 'Seeding' 'Seeding'
	& $def 'f_auto' 'Automatisch (empfohlen): SQL Server überträgt die Datenbanken selbst' 'Automatic (recommended): SQL Server transfers the databases itself'
	& $def 'f_manual' 'Manuell: Backup und Restore über eine Freigabe' 'Manual: backup and restore via a share'
	& $def 'f_bak' 'Backup-Pfad (UNC-Freigabe, beide SQL-Dienstkonten brauchen Zugriff)' 'Backup path (UNC share, both SQL service accounts need access)'
	& $def 'f_out' 'Ordner für Berichte' 'Folder for reports'
	& $def 'f_listener' 'Listener-Name für den Umzug (optional, leer = nur einer erwartet)' 'Listener name for the move (optional, empty = only one expected)'
	& $def 'f_lport' 'Listener-Port' 'Listener port'

	# Seite 3
	& $def 'p_run' 'Prüfung starten' 'Run checks'
	& $def 'p_ack' 'Ich habe die Warnungen gelesen und möchte fortfahren' 'I have read the warnings and want to continue'
	& $def 'p_sum' '{0} bestanden, {1} Warnung(en), {2} Fehler' '{0} passed, {1} warning(s), {2} error(s)'
	& $def 'p_running' 'Prüfung läuft ...' 'Checking ...'
	& $def 'p_ok' 'OK' 'OK'
	& $def 'p_warn' 'Warnung' 'Warning'
	& $def 'p_fail' 'Fehler' 'Error'
	& $def 'p_col0' 'Status' 'Status'
	& $def 'p_col1' 'Prüfung' 'Check'
	& $def 'p_col2' 'Ergebnis' 'Result'
	& $def 'p_col3' 'Lösung' 'Remedy'
	& $def 'p_fixfirst' 'Beheben Sie die Fehler und starten Sie die Prüfung erneut.' 'Fix the errors and run the checks again.'
	& $def 'p_clean' 'Alle Prüfungen bestanden. Sie können fortfahren.' 'All checks passed. You can continue.'

	# Seite 4
	& $def 'u_dry' 'Trockenlauf ausführen' 'Run dry run'
	& $def 'u_confirm' 'Zur Bestätigung geben Sie den Namen der Distributed AG ein:' 'To confirm, enter the name of the Distributed AG:'
	& $def 'u_mismatch' 'Der Name stimmt nicht überein.' 'The name does not match.'
	& $def 'u_sqlprev' 'T-SQL-Vorschau (wird von den Funktionen so ausgeführt)' 'T-SQL preview (executed like this by the functions)'
	& $def 'u_plan' 'Geplante Aktionen' 'Planned actions'
	& $def 'u_dryok' 'Trockenlauf erfolgreich: {0}' 'Dry run successful: {0}'
	& $def 'u_dryfail' 'Trockenlauf fehlgeschlagen.' 'Dry run failed.'
	& $def 'u_copy' 'T-SQL kopieren' 'Copy T-SQL'

	# Seite 5
	& $def 'x_step' 'Schritt' 'Step'
	& $def 'x_state' 'Status' 'Status'
	& $def 'x_detail' 'Details' 'Details'
	& $def 'x_wait' 'Wartet' 'Pending'
	& $def 'x_run' 'Läuft' 'Running'
	& $def 'x_done' 'Fertig' 'Done'
	& $def 'x_skip' 'Übersprungen' 'Skipped'
	& $def 'x_fail' 'Fehler' 'Failed'
	& $def 'x_cause' 'Ursache' 'Cause'
	& $def 'x_fix' 'Lösungsvorschlag' 'Suggested fix'
	& $def 'x_retry' 'Wiederholen' 'Retry'
	& $def 'x_skipbtn' 'Überspringen' 'Skip'
	& $def 'x_abort' 'Abbrechen' 'Abort'
	& $def 'x_raw' 'Technische Meldung' 'Technical message'
	& $def 'x_dag' 'Distributed AG anlegen' 'Create Distributed AG'
	& $def 'x_db' 'Datenbank {0} übertragen' 'Transfer database {0}'
	& $def 'x_allok' 'Alle Schritte abgeschlossen. Weiter mit der Synchronisation.' 'All steps completed. Continue with synchronization.'
	& $def 'x_aborted' 'Die Ausführung wurde abgebrochen. Ihre Migration ist gespeichert und kann über "Fortsetzen" wieder aufgenommen werden.' 'Execution was aborted. Your migration is saved and can be resumed via "Resume".'

	# Seite 6
	& $def 'y_db' 'Datenbank' 'Database'
	& $def 'y_state' 'Zustand' 'State'
	& $def 'y_health' 'Gesundheit' 'Health'
	& $def 'y_send' 'Send-Queue (KB)' 'Send queue (KB)'
	& $def 'y_redo' 'Redo-Queue (KB)' 'Redo queue (KB)'
	& $def 'y_seed' 'Seeding' 'Seeding'
	& $def 'y_ready' 'Alle Datenbanken sind bereit für das Failover.' 'All databases are ready for failover.'
	& $def 'y_notready' 'Noch nicht bereit: {0}' 'Not ready yet: {0}'
	& $def 'y_poll' 'Letzte Aktualisierung: {0}' 'Last refresh: {0}'
	& $def 'y_err' 'Abfrage fehlgeschlagen: {0}' 'Query failed: {0}'
	& $def 'y_refresh' 'Jetzt aktualisieren' 'Refresh now'

	# Seite 7
	& $def 'l_name' 'Listener-Name' 'Listener name'
	& $def 'l_port' 'Port' 'Port'
	& $def 'l_a' 'Phase A: Listener von der bisherigen AG entfernen' 'Phase A: remove the listener from the current AG'
	& $def 'l_a_btn' 'Listener jetzt entfernen' 'Remove listener now'
	& $def 'l_a_info' 'Die Datenbanken bleiben online. Danach muss das Cluster-/AD-Team die Listener-Ressource löschen und auf dem Ziel-Cluster neu anlegen.' 'The databases stay online. Afterwards the cluster/AD team must delete the listener resource and recreate it on the target cluster.'
	& $def 'l_b' 'Phase B: Cluster-/AD-Team legt den Listener auf dem Ziel-Cluster an' 'Phase B: cluster/AD team creates the listener on the target cluster'
	& $def 'l_b_copy' 'Anweisung kopieren' 'Copy instruction'
	& $def 'l_b_wait' 'Pflicht-Wartezeit für DNS und Anwendungs-Timeouts: {0}' 'Mandatory wait for DNS and application timeouts: {0}'
	& $def 'l_b_waitdone' 'Wartezeit abgelaufen.' 'Waiting time elapsed.'
	& $def 'l_b_skipwait' 'Wartezeit überspringen (DNS-TTL ist bereits abgelaufen)' 'Skip waiting time (DNS TTL has already expired)'
	& $def 'l_b_team' 'Das Cluster-/AD-Team bestätigt: Der Listener ist auf dem Ziel-Cluster angelegt und online' 'The cluster/AD team confirms: the listener exists on the target cluster and is online'
	& $def 'l_c' 'Phase C: Listener an der Ziel-AG registrieren' 'Phase C: register the listener with the target AG'
	& $def 'l_c_btn' 'Listener jetzt registrieren' 'Register listener now'
	& $def 'l_skip' 'Kein Listener-Umzug nötig (die AG hat keinen Listener oder er wird später umgezogen)' 'No listener move needed (the AG has no listener or it will be moved later)'
	& $def 'l_done' 'Erledigt' 'Done'
	& $def 'l_instr' "Bitte auf dem Ziel-Cluster die Listener-Ressource anlegen:`r`n`r`nAG: {0}`r`nListener-DNS-Name: {1}`r`nPort: {2}`r`nIP-Adresse(n): {3}`r`n`r`nVorgehen:`r`n1. Auf dem alten Cluster ist die Listener-Ressource bereits aus der AG entfernt. Die Rolle darf jetzt gelöscht werden.`r`n2. Auf dem Ziel-Cluster einen Client-Access-Point mit demselben DNS-Namen und der IP-Adresse anlegen und der AG-Rolle zuordnen.`r`n3. Sicherstellen, dass die Ressource online ist und der DNS-Name auflöst.`r`n4. Rückmeldung an das DBA-Team." "Please create the listener resource on the target cluster:`r`n`r`nAG: {0}`r`nListener DNS name: {1}`r`nPort: {2}`r`nIP address(es): {3}`r`n`r`nProcedure:`r`n1. On the old cluster the listener resource has already been removed from the AG. The role may be deleted now.`r`n2. On the target cluster create a client access point with the same DNS name and IP address and assign it to the AG role.`r`n3. Make sure the resource is online and the DNS name resolves.`r`n4. Report back to the DBA team."

	# Seite 8
	& $def 'o_check1' 'Alle betroffenen Anwendungen und Teams sind über die kurze Unterbrechung informiert' 'All affected applications and teams are informed about the short interruption'
	& $def 'o_check2' 'Ich weiß, dass beide Seiten nach dem Failover auf SYNCHRONOUS_COMMIT stehen' 'I know that both sides stay on SYNCHRONOUS_COMMIT after the failover'
	& $def 'o_confirm' 'Zur Bestätigung geben Sie den Namen der Distributed AG ein:' 'To confirm, enter the name of the Distributed AG:'
	& $def 'o_go' 'Failover jetzt ausführen' 'Run failover now'
	& $def 'o_rb' 'Rollback zum alten Cluster' 'Roll back to the old cluster'
	& $def 'o_rbask' 'Rollback ausführen? Der alte Cluster wird wieder Primary und die Anwendungen verlieren kurz die Verbindung.' 'Run the rollback? The old cluster becomes primary again and applications briefly lose their connection.'
	& $def 'o_ok' 'Failover abgeschlossen. Neuer Primary: {0}' 'Failover completed. New primary: {0}'
	& $def 'o_rbok' 'Rollback abgeschlossen. Primary: {0}' 'Rollback completed. Primary: {0}'
	& $def 'o_notready' 'Das Failover ist gesperrt, solange nicht alle Datenbanken bereit sind.' 'Failover is blocked until all databases are ready.'
	& $def 'o_state' 'Aktueller Zustand' 'Current state'

	# Seite 9
	& $def 'z_clean' 'Aufräumen (nach einigen Tagen Betrieb, bewusst und manuell):' 'Clean up (after some days of operation, deliberately and manually):'
	& $def 'z_note' "1. Prüfen Sie, dass alle Anwendungen auf dem neuen Cluster arbeiten.`r`n2. Entfernen Sie die Distributed AG auf beiden Seiten (T-SQL unten). Danach sind beide Cluster unabhängig.`r`n3. Außerbetriebnahme des alten Clusters nach Ablauf der Aufbewahrungsfrist." "1. Verify that all applications work on the new cluster.`r`n2. Remove the Distributed AG on both sides (T-SQL below). Afterwards both clusters are independent.`r`n3. Decommission the old cluster after the retention period."
	& $def 'z_copy' 'Aufräum-T-SQL kopieren' 'Copy clean-up T-SQL'
	& $def 'z_openrep' 'Berichtsordner öffnen' 'Open report folder'
	& $def 'z_rollbackhint' 'Ein Rollback ist nur bis zum Entfernen der Distributed AG möglich.' 'A rollback is only possible until the Distributed AG is removed.'

	# Meldungen
	& $def 'm_close_busy' 'Ein Schritt läuft noch. Er lässt sich nicht sicher abbrechen. Beim nächsten Start können Sie über "Fortsetzen" weitermachen. Trotzdem schließen?' 'A step is still running. It cannot be stopped safely. Next time you can continue via "Resume". Close anyway?'
	& $def 'm_close_mig' 'Die Migration ist noch nicht abgeschlossen. Ihr Stand ist gespeichert. Fenster schließen?' 'The migration is not finished. Your progress is saved. Close the window?'
	& $def 'm_err' 'Unerwarteter Fehler in der Oberfläche: {0}' 'Unexpected error in the interface: {0}'
	& $def 'm_startask' 'Die Migration startet jetzt und verändert beide Server (Distributed AG anlegen). Fortfahren?' 'The migration starts now and changes both servers (creating the Distributed AG). Continue?'
	& $def 'm_lerr' 'Listener-Schritt fehlgeschlagen' 'Listener step failed'

	# =====================================================================
	# Farben, Schriften, Zustand
	# =====================================================================
	$cBack = [System.Drawing.Color]::White
	$cSide = [System.Drawing.Color]::FromArgb(243, 243, 243)
	$cBar = [System.Drawing.Color]::FromArgb(240, 240, 240)
	$cText = [System.Drawing.Color]::FromArgb(32, 32, 32)
	$cDim = [System.Drawing.Color]::FromArgb(96, 96, 96)
	$cAccent = [System.Drawing.Color]::FromArgb(0, 120, 212)
	$cOk = [System.Drawing.Color]::FromArgb(16, 124, 16)
	$cWarn = [System.Drawing.Color]::FromArgb(157, 93, 0)
	$cErr = [System.Drawing.Color]::FromArgb(196, 43, 28)
	$cLine = [System.Drawing.Color]::FromArgb(218, 218, 218)
	$fBase = New-Object System.Drawing.Font('Segoe UI', 9)
	$fBold = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
	$fTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
	$fMono = New-Object System.Drawing.Font('Consolas', 9)

	$S = @{
		Lang = $Language; Page = 0; Flow = @(0..9); Mode = 'New'; Cred = $null
		Connected = $false; ConnSig = ''; AgRoles = @{ }; SrcFqdn = ''; TgtFqdn = ''; DagList = @()
		Config = @{ }; Checks = $null; PreflightRan = $false; Warnings = 0; Blockers = 0; DbList = @()
		Texts = [System.Collections.Generic.List[object]]::new()
		Job = $null; PJob = $null; OnStep = $null; OnDone = $null; Busy = $false
		Units = @(); UnitIndex = 0; UnitDone = @{ }; Lock = $null; StatePage = 0
		SyncReady = $false; SyncReasons = ''; ListenerA = $false; ListenerC = $false; ListenerInfo = $null
		WaitUntil = $null; FailoverDone = $false; RolledBack = $false; Started = $false; Aborted = $false
		ResumePage = -1; StateDir = $StatePath; ReportDir = ''; LastPoll = $null; LogLines = [System.Collections.Generic.List[string]]::new()
		Dry = $false; DryOk = $false; DryText = ''
	}
	$UI = @{ }
	$Pages = @{ }

	$Tr = {
		param ([string]$k, [object[]]$a)
		$str = $Tx[$S.Lang][$k]
		if ($null -eq $str) { $str = $k }
		if ($a -and $a.Count -gt 0) { return ($str -f $a) }
		return $str
	}
	$Reg = {
		param ($ctl, [string]$key)
		$S.Texts.Add(@{ C = $ctl; K = $key })
		$ctl.Text = (& $Tr $key)
	}

	# =====================================================================
	# Formular-Skelett
	# =====================================================================
	$form = New-Object System.Windows.Forms.Form
	$form.Text = (& $Tr 'title')
	$form.Size = New-Object System.Drawing.Size(1060, 760)
	$form.MinimumSize = New-Object System.Drawing.Size(980, 700)
	$form.StartPosition = 'CenterScreen'
	$form.Font = $fBase
	$form.BackColor = $cBack
	$form.ForeColor = $cText

	$status = New-Object System.Windows.Forms.StatusStrip
	$statusLbl = New-Object System.Windows.Forms.ToolStripStatusLabel
	[void]$status.Items.Add($statusLbl)
	$form.Controls.Add($status)

	$tbl = New-Object System.Windows.Forms.TableLayoutPanel
	$tbl.Dock = 'Fill'
	$tbl.ColumnCount = 2
	$tbl.RowCount = 4
	[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 230)))
	[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
	[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 78)))
	[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
	[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 0)))
	[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 54)))
	$tbl.Margin = New-Object System.Windows.Forms.Padding(0)
	$form.Controls.Add($tbl)
	$tbl.BringToFront()

	# Seitenleiste
	$pnlSide = New-Object System.Windows.Forms.Panel
	$pnlSide.Dock = 'Fill'
	$pnlSide.BackColor = $cSide
	$pnlSide.Margin = New-Object System.Windows.Forms.Padding(0)
	$tbl.Controls.Add($pnlSide, 0, 0)
	$tbl.SetRowSpan($pnlSide, 4)

	$lblBrand = New-Object System.Windows.Forms.Label
	$lblBrand.Location = New-Object System.Drawing.Point(16, 18)
	$lblBrand.Size = New-Object System.Drawing.Size(200, 44)
	$lblBrand.Font = $fBold
	$lblBrand.ForeColor = $cAccent
	$pnlSide.Controls.Add($lblBrand)
	& $Reg $lblBrand 'title'

	$flowSteps = New-Object System.Windows.Forms.FlowLayoutPanel
	$flowSteps.Location = New-Object System.Drawing.Point(0, 76)
	$flowSteps.Size = New-Object System.Drawing.Size(230, 520)
	$flowSteps.Anchor = 'Top,Left,Bottom'
	$flowSteps.FlowDirection = 'TopDown'
	$flowSteps.WrapContents = $false
	$pnlSide.Controls.Add($flowSteps)
	$stepLabels = @()
	foreach ($i in 0..9)
	{
		$l = New-Object System.Windows.Forms.Label
		$l.Size = New-Object System.Drawing.Size(226, 34)
		$l.Margin = New-Object System.Windows.Forms.Padding(0)
		$l.Padding = New-Object System.Windows.Forms.Padding(18, 0, 0, 0)
		$l.TextAlign = 'MiddleLeft'
		$flowSteps.Controls.Add($l)
		$stepLabels += $l
	}

	# Sprachumschalter in der Seitenleiste
	$btnLang = New-Object System.Windows.Forms.Button
	$btnLang.Size = New-Object System.Drawing.Size(90, 28)
	$btnLang.Location = New-Object System.Drawing.Point(16, 650)
	$btnLang.Anchor = 'Bottom,Left'
	$btnLang.FlatStyle = 'Flat'
	$btnLang.FlatAppearance.BorderColor = $cLine
	$btnLang.BackColor = $cBack
	$pnlSide.Controls.Add($btnLang)

	# Kopf
	$pnlHead = New-Object System.Windows.Forms.Panel
	$pnlHead.Dock = 'Fill'
	$pnlHead.BackColor = $cBack
	$pnlHead.Margin = New-Object System.Windows.Forms.Padding(0)
	$tbl.Controls.Add($pnlHead, 1, 0)
	$lblTitle = New-Object System.Windows.Forms.Label
	$lblTitle.Location = New-Object System.Drawing.Point(24, 10)
	$lblTitle.Size = New-Object System.Drawing.Size(760, 34)
	$lblTitle.Anchor = 'Top,Left,Right'
	$lblTitle.Font = $fTitle
	$pnlHead.Controls.Add($lblTitle)
	$lblSub = New-Object System.Windows.Forms.Label
	$lblSub.Location = New-Object System.Drawing.Point(26, 46)
	$lblSub.Size = New-Object System.Drawing.Size(760, 24)
	$lblSub.Anchor = 'Top,Left,Right'
	$lblSub.ForeColor = $cDim
	$pnlHead.Controls.Add($lblSub)

	# Inhalt
	$pnlContent = New-Object System.Windows.Forms.Panel
	$pnlContent.Dock = 'Fill'
	$pnlContent.BackColor = $cBack
	$pnlContent.Margin = New-Object System.Windows.Forms.Padding(0)
	$tbl.Controls.Add($pnlContent, 1, 1)

	# Protokoll
	$pnlLog = New-Object System.Windows.Forms.Panel
	$pnlLog.Dock = 'Fill'
	$pnlLog.Margin = New-Object System.Windows.Forms.Padding(0)
	$pnlLog.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)
	$tbl.Controls.Add($pnlLog, 1, 2)
	$rtb = New-Object System.Windows.Forms.RichTextBox
	$rtb.Dock = 'Fill'
	$rtb.ReadOnly = $true
	$rtb.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)
	$rtb.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
	$rtb.Font = $fMono
	$rtb.BorderStyle = 'None'
	$pnlLog.Controls.Add($rtb)

	# Knopfleiste
	$pnlBtn = New-Object System.Windows.Forms.Panel
	$pnlBtn.Dock = 'Fill'
	$pnlBtn.BackColor = $cBar
	$pnlBtn.Margin = New-Object System.Windows.Forms.Padding(0)
	$tbl.Controls.Add($pnlBtn, 1, 3)

	$mkBtn = {
		param ([string]$key, [int]$w, [string]$anchor)
		$b = New-Object System.Windows.Forms.Button
		$b.Size = New-Object System.Drawing.Size($w, 32)
		$b.FlatStyle = 'Flat'
		$b.FlatAppearance.BorderColor = $cLine
		$b.BackColor = $cBack
		$b.ForeColor = $cText
		$b.Anchor = $anchor
		if ($key) { & $Reg $b $key }
		return $b
	}
	$btnLog = & $mkBtn 'showlog' 170 'Top,Left'
	$btnLog.Location = New-Object System.Drawing.Point(16, 11)
	$pnlBtn.Controls.Add($btnLog)
	$btnSaveLog = & $mkBtn 'savelog' 150 'Top,Left'
	$btnSaveLog.Location = New-Object System.Drawing.Point(194, 11)
	$pnlBtn.Controls.Add($btnSaveLog)
	$btnCancel = & $mkBtn 'cancel' 110 'Top,Right'
	$pnlBtn.Controls.Add($btnCancel)
	$btnNext = & $mkBtn 'next' 120 'Top,Right'
	$btnNext.BackColor = $cAccent
	$btnNext.ForeColor = [System.Drawing.Color]::White
	$btnNext.FlatAppearance.BorderColor = $cAccent
	$pnlBtn.Controls.Add($btnNext)
	$btnBack = & $mkBtn 'back' 110 'Top,Right'
	$pnlBtn.Controls.Add($btnBack)
	$placeButtons = {
		$w = $pnlBtn.ClientSize.Width
		$btnCancel.Location = New-Object System.Drawing.Point(($w - 126), 11)
		$btnNext.Location = New-Object System.Drawing.Point(($w - 126 - 130), 11)
		$btnBack.Location = New-Object System.Drawing.Point(($w - 126 - 130 - 120), 11)
	}
	$pnlBtn.Add_Resize($placeButtons)

	$ep = New-Object System.Windows.Forms.ErrorProvider
	$ep.BlinkStyle = 'NeverBlink'
	$ep.ContainerControl = $form

	$tmr = New-Object System.Windows.Forms.Timer
	$tmr.Interval = 400
	$tmrSync = New-Object System.Windows.Forms.Timer
	$tmrSync.Interval = 10000
	$tmrWait = New-Object System.Windows.Forms.Timer
	$tmrWait.Interval = 1000

	# =====================================================================
	# Hilfsfunktionen
	# =====================================================================
	$Log = {
		param ([string]$msg, [string]$level = 'INFO')
		$color = switch ($level)
		{
			'ERROR' { [System.Drawing.Color]::FromArgb(255, 110, 110) }
			'WARN' { [System.Drawing.Color]::FromArgb(255, 200, 80) }
			'OK' { [System.Drawing.Color]::FromArgb(110, 220, 110) }
			default { [System.Drawing.Color]::FromArgb(210, 210, 210) }
		}
		$line = "{0:HH:mm:ss}  {1}" -f (Get-Date), $msg
		$S.LogLines.Add($line)
		try
		{
			$rtb.SelectionStart = $rtb.TextLength
			$rtb.SelectionColor = $color
			$rtb.AppendText($line + "`r`n")
			$rtb.ScrollToCaret()
		}
		catch { Write-Verbose $_.Exception.Message }
		try { Invoke-sqmLogging -Message $msg -FunctionName 'Show-sqmDistributedAgGui' -Level $(if ($level -eq 'WARN') { 'WARNING' } elseif ($level -eq 'OK') { 'INFO' } else { $level }) } catch { Write-Verbose $_.Exception.Message }
	}
	$Guard = {
		param ([scriptblock]$body)
		try { & $body }
		catch
		{
			$m = $_.Exception.Message
			$where = ''
			try { $where = $_.InvocationInfo.PositionMessage } catch { Write-Verbose $_.Exception.Message }
			try
			{
				$dir = Join-Path $env:LOCALAPPDATA 'sqmSQLTool'
				if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
				Add-Content -Path (Join-Path $dir 'gui-launch.log') -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  DistributedAgGui: $m`r`n$where" -Encoding UTF8
			}
			catch { Write-Verbose $_.Exception.Message }
			& $Log (& $Tr 'm_err' @($m)) 'ERROR'
			[void][System.Windows.Forms.MessageBox]::Show((& $Tr 'm_err' @($m)), (& $Tr 'title'), 'OK', 'Error')
		}
	}
	$SetStatus = {
		param ([string]$txt)
		$statusLbl.Text = $txt
	}
	$Cur = { return [int]$S.Flow[$S.Page] }

	# Zustand speichern (ohne Geheimnisse)
	$SaveState = {
		if (-not $S.Config.SourceAgName -or -not $S.Config.TargetAgName) { return }
		try
		{
			$st = @{
				SourceAgName = $S.Config.SourceAgName; TargetAgName = $S.Config.TargetAgName
				Mode = $S.Mode; Page = $S.StatePage; Config = $S.Config; DbList = $S.DbList
				UnitDone = @($S.UnitDone.Keys); ListenerA = $S.ListenerA; ListenerC = $S.ListenerC
				FailoverDone = $S.FailoverDone; RolledBack = $S.RolledBack; Started = $S.Started
				SourceFqdn = $S.Config.SourceFqdn; TargetFqdn = $S.Config.TargetFqdn
			}
			$a = @{ State = $st }
			if ($S.StateDir) { $a['BasePath'] = $S.StateDir }
			[void](Save-sqmDagMigrationState @a)
		}
		catch { & $Log "Zustand konnte nicht gespeichert werden: $($_.Exception.Message)" 'WARN' }
	}

	# Hintergrundjob
	$StartJob = {
		param ([string]$code, [object[]]$jobArgs, [scriptblock]$onStep, [scriptblock]$onDone)
		$S.OnStep = $onStep
		$S.OnDone = $onDone
		$S.Busy = $true
		$S.Job = Start-sqmDagBackgroundJob -Code $code -ArgumentList $jobArgs
		$tmr.Start()
		& $UpdateNav
		$form.Cursor = [System.Windows.Forms.Cursors]::AppStarting
	}

	# =====================================================================
	# Seiten bauen
	# =====================================================================
	$mkPage = {
		$p = New-Object System.Windows.Forms.Panel
		$p.Size = New-Object System.Drawing.Size(814, 590)
		$p.Dock = 'Fill'
		$p.AutoScroll = $true
		$p.Padding = New-Object System.Windows.Forms.Padding(24, 12, 24, 12)
		$p.BackColor = $cBack
		$p.Visible = $false
		$pnlContent.Controls.Add($p)
		return $p
	}
	$mkLabel = {
		param ($parent, [string]$key, [int]$x, [int]$y, [int]$w, [int]$h = 22, [bool]$bold = $false, [string]$anchor = 'Top,Left')
		$l = New-Object System.Windows.Forms.Label
		$l.Location = New-Object System.Drawing.Point($x, $y)
		$l.Size = New-Object System.Drawing.Size($w, $h)
		$l.Anchor = $anchor
		$l.ForeColor = $cText
		if ($bold) { $l.Font = $fBold }
		$parent.Controls.Add($l)
		if ($key) { & $Reg $l $key }
		return $l
	}
	$mkText = {
		param ($parent, [int]$x, [int]$y, [int]$w, [string]$anchor = 'Top,Left,Right')
		$t = New-Object System.Windows.Forms.TextBox
		$t.Location = New-Object System.Drawing.Point($x, $y)
		$t.Size = New-Object System.Drawing.Size($w, 24)
		$t.Anchor = $anchor
		$parent.Controls.Add($t)
		return $t
	}
	$mkCombo = {
		param ($parent, [int]$x, [int]$y, [int]$w)
		$c = New-Object System.Windows.Forms.ComboBox
		$c.Location = New-Object System.Drawing.Point($x, $y)
		$c.Size = New-Object System.Drawing.Size($w, 24)
		$c.DropDownStyle = 'DropDownList'
		$parent.Controls.Add($c)
		return $c
	}
	$mkRadio = {
		param ($parent, [string]$key, [int]$x, [int]$y, [int]$w)
		$r = New-Object System.Windows.Forms.RadioButton
		$r.Location = New-Object System.Drawing.Point($x, $y)
		$r.Size = New-Object System.Drawing.Size($w, 24)
		$parent.Controls.Add($r)
		& $Reg $r $key
		return $r
	}
	$mkButton = {
		param ($parent, [string]$key, [int]$x, [int]$y, [int]$w, [bool]$primary = $false)
		$b = New-Object System.Windows.Forms.Button
		$b.Location = New-Object System.Drawing.Point($x, $y)
		$b.Size = New-Object System.Drawing.Size($w, 30)
		$b.FlatStyle = 'Flat'
		$b.FlatAppearance.BorderColor = $(if ($primary) { $cAccent } else { $cLine })
		$b.BackColor = $(if ($primary) { $cAccent } else { $cBack })
		$b.ForeColor = $(if ($primary) { [System.Drawing.Color]::White } else { $cText })
		$parent.Controls.Add($b)
		& $Reg $b $key
		return $b
	}
	$mkList = {
		param ($parent, [int]$x, [int]$y, [int]$w, [int]$h, [string[]]$colKeys, [int[]]$colW)
		$lv = New-Object System.Windows.Forms.ListView
		$lv.Location = New-Object System.Drawing.Point($x, $y)
		$lv.Size = New-Object System.Drawing.Size($w, $h)
		$lv.Anchor = 'Top,Left,Right,Bottom'
		$lv.View = 'Details'
		$lv.FullRowSelect = $true
		$lv.HideSelection = $false
		$lv.HeaderStyle = 'Nonclickable'
		$lv.Font = $fBase
		for ($i = 0; $i -lt $colKeys.Count; $i++)
		{
			$col = New-Object System.Windows.Forms.ColumnHeader
			$col.Width = $colW[$i]
			$lv.Columns.Add($col) | Out-Null
			$S.Texts.Add(@{ C = $col; K = $colKeys[$i] })
			$col.Text = (& $Tr $colKeys[$i])
		}
		$parent.Controls.Add($lv)
		return $lv
	}
	$mkMulti = {
		param ($parent, [int]$x, [int]$y, [int]$w, [int]$h, [bool]$mono = $false)
		$t = New-Object System.Windows.Forms.TextBox
		$t.Multiline = $true
		$t.ReadOnly = $true
		$t.ScrollBars = 'Vertical'
		$t.Location = New-Object System.Drawing.Point($x, $y)
		$t.Size = New-Object System.Drawing.Size($w, $h)
		$t.Anchor = 'Top,Left,Right'
		$t.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
		if ($mono) { $t.Font = $fMono }
		$parent.Controls.Add($t)
		return $t
	}

	# ---------- Seite 0: Willkommen ----------
	$p0 = & $mkPage
	$Pages[0] = $p0
	$UI.intro = & $mkLabel $p0 'w_intro' 0 4 760 62 $false 'Top,Left,Right'
	$UI.diagram = New-Object System.Windows.Forms.Panel
	$UI.diagram.Location = New-Object System.Drawing.Point(0, 76)
	$UI.diagram.Size = New-Object System.Drawing.Size(780, 86)
	$UI.diagram.Anchor = 'Top,Left,Right'
	$p0.Controls.Add($UI.diagram)
	$UI.diagram.Add_Paint({
			$sndr = $args[0]
			$g = $args[1].Graphics
			$g.SmoothingMode = 'AntiAlias'
			$keys = 'd_src', 'd_dag', 'd_tgt', 'd_fo', 'd_clean'
			$n = $keys.Count
			$w = $sndr.ClientSize.Width
			$bw = [int](($w - 20 - ($n - 1) * 34) / $n)
			$pen = New-Object System.Drawing.Pen($cAccent, 2)
			$brush = New-Object System.Drawing.SolidBrush($cAccent)
			$sf = New-Object System.Drawing.StringFormat
			$sf.Alignment = 'Center'
			$sf.LineAlignment = 'Center'
			for ($i = 0; $i -lt $n; $i++)
			{
				$x = 10 + $i * ($bw + 34)
				$rect = New-Object System.Drawing.RectangleF($x, 12, $bw, 56)
				$fill = if ($i -eq 1) { [System.Drawing.Color]::FromArgb(222, 236, 249) } else { [System.Drawing.Color]::FromArgb(246, 246, 246) }
				$fb = New-Object System.Drawing.SolidBrush($fill)
				$g.FillRectangle($fb, $rect)
				$g.DrawRectangle($pen, $x, 12, $bw, 56)
				$tb = New-Object System.Drawing.SolidBrush($cText)
				$g.DrawString((& $Tr $keys[$i]), $fBold, $tb, $rect, $sf)
				if ($i -lt ($n - 1))
				{
					$ax = $x + $bw + 4
					$g.DrawLine($pen, $ax, 40, ($ax + 22), 40)
					$pts = @(
						(New-Object System.Drawing.Point(($ax + 22), 33)),
						(New-Object System.Drawing.Point(($ax + 28), 40)),
						(New-Object System.Drawing.Point(($ax + 22), 47))
					)
					$g.FillPolygon($brush, $pts)
				}
			}
		})
	$UI.lblWhat = & $mkLabel $p0 'w_what' 0 176 500 24 $true
	$UI.rbNew = & $mkRadio $p0 'w_new' 8 206 700
	$UI.rbNew.Checked = $true
	$UI.rbResume = & $mkRadio $p0 'w_resume' 8 236 700
	$UI.cmbResume = & $mkCombo $p0 34 264 640
	$UI.cmbResume.Anchor = 'Top,Left,Right'
	$UI.cmbResume.Enabled = $false
	$UI.lblNoResume = & $mkLabel $p0 '' 34 292 640 20
	$UI.lblNoResume.ForeColor = $cDim
	$UI.rbOps = & $mkRadio $p0 'w_ops' 8 320 760
	$UI.lblPrereq = & $mkLabel $p0 'w_prereq' 0 366 760 44 $false 'Top,Left,Right'
	$UI.lblPrereq.ForeColor = $cDim

	# ---------- Seite 1: Verbindung ----------
	$p1 = & $mkPage
	$Pages[1] = $p1
	$UI.gSrc = & $mkLabel $p1 'c_src' 0 6 380 22 $true
	$UI.lSrcInst = & $mkLabel $p1 'c_inst' 0 32 380 20
	$UI.txtSrcInst = & $mkText $p1 0 54 380 'Top,Left'
	$UI.lSrcAg = & $mkLabel $p1 'c_ag' 0 86 380 20
	$UI.cmbSrcAg = & $mkCombo $p1 0 108 380
	$UI.gTgt = & $mkLabel $p1 'c_tgt' 400 6 380 22 $true
	$UI.lTgtInst = & $mkLabel $p1 'c_inst' 400 32 380 20
	$UI.txtTgtInst = & $mkText $p1 400 54 380 'Top,Left'
	$UI.lTgtAg = & $mkLabel $p1 'c_ag' 400 86 380 20
	$UI.cmbTgtAg = & $mkCombo $p1 400 108 380
	$UI.lDag = & $mkLabel $p1 'c_dag' 0 86 380 20
	$UI.cmbDag = & $mkCombo $p1 0 108 380
	$UI.lDag.Visible = $false
	$UI.cmbDag.Visible = $false
	$UI.lAuth = & $mkLabel $p1 'c_auth' 0 156 380 22 $true
	$UI.rbWin = & $mkRadio $p1 'c_win' 8 182 500
	$UI.rbWin.Checked = $true
	$UI.rbSql = & $mkRadio $p1 'c_sql' 8 208 300
	$UI.lUser = & $mkLabel $p1 'c_user' 34 238 160 20
	$UI.txtUser = & $mkText $p1 34 260 240 'Top,Left'
	$UI.lPwd = & $mkLabel $p1 'c_pwd' 290 238 160 20
	$UI.txtPwd = & $mkText $p1 290 260 240 'Top,Left'
	$UI.txtPwd.UseSystemPasswordChar = $true
	$UI.lUser.Enabled = $false; $UI.txtUser.Enabled = $false; $UI.lPwd.Enabled = $false; $UI.txtPwd.Enabled = $false
	$UI.btnTest = & $mkButton $p1 'c_test' 0 306 300 $true
	$UI.prog1 = New-Object System.Windows.Forms.ProgressBar
	$UI.prog1.Style = 'Marquee'
	$UI.prog1.MarqueeAnimationSpeed = 30
	$UI.prog1.Location = New-Object System.Drawing.Point(312, 313)
	$UI.prog1.Size = New-Object System.Drawing.Size(180, 16)
	$UI.prog1.Visible = $false
	$p1.Controls.Add($UI.prog1)
	$UI.lblConn = & $mkLabel $p1 '' 0 348 780 90 $false 'Top,Left,Right'
	$UI.lblHint1 = & $mkLabel $p1 'c_hint' 0 444 780 40 $false 'Top,Left,Right'
	$UI.lblHint1.ForeColor = $cDim

	# ---------- Seite 2: Konfiguration ----------
	$p2 = & $mkPage
	$Pages[2] = $p2
	$UI.lDagName = & $mkLabel $p2 'f_dagname' 0 6 380 20
	$UI.txtDagName = & $mkText $p2 0 28 380 'Top,Left'
	$UI.lPort = & $mkLabel $p2 'f_port' 400 6 200 20
	$UI.txtPort = & $mkText $p2 400 28 120 'Top,Left'
	$UI.txtPort.Text = '5022'
	$UI.lSrcFqdn = & $mkLabel $p2 'f_srcfqdn' 0 62 380 20
	$UI.txtSrcFqdn = & $mkText $p2 0 84 380 'Top,Left'
	$UI.lTgtFqdn = & $mkLabel $p2 'f_tgtfqdn' 400 62 380 20
	$UI.txtTgtFqdn = & $mkText $p2 400 84 380 'Top,Left'
	$UI.lAcct = & $mkLabel $p2 'f_acct' 0 118 780 20 $false 'Top,Left,Right'
	$UI.txtAcct = & $mkText $p2 0 140 380 'Top,Left'
	$UI.lSeed = & $mkLabel $p2 'f_seed' 0 178 300 22 $true
	$UI.rbAuto = & $mkRadio $p2 'f_auto' 8 202 760
	$UI.rbAuto.Checked = $true
	$UI.rbManual = & $mkRadio $p2 'f_manual' 8 228 760
	$UI.lBak = & $mkLabel $p2 'f_bak' 34 258 740 20
	$UI.txtBak = & $mkText $p2 34 280 500 'Top,Left'
	$UI.lBak.Enabled = $false; $UI.txtBak.Enabled = $false
	$UI.lOut = & $mkLabel $p2 'f_out' 0 318 380 20
	$UI.txtOut = & $mkText $p2 0 340 500 'Top,Left'
	$UI.lLis = & $mkLabel $p2 'f_listener' 0 376 600 20
	$UI.txtListener = & $mkText $p2 0 398 380 'Top,Left'
	$UI.lLport = & $mkLabel $p2 'f_lport' 400 376 200 20
	$UI.txtLport = & $mkText $p2 400 398 120 'Top,Left'
	$UI.txtLport.Text = '1433'

	# ---------- Seite 3: Vorabpruefung ----------
	$p3 = & $mkPage
	$Pages[3] = $p3
	$UI.btnCheck = & $mkButton $p3 'p_run' 0 4 180 $true
	$UI.prog3 = New-Object System.Windows.Forms.ProgressBar
	$UI.prog3.Style = 'Marquee'
	$UI.prog3.MarqueeAnimationSpeed = 30
	$UI.prog3.Location = New-Object System.Drawing.Point(194, 11)
	$UI.prog3.Size = New-Object System.Drawing.Size(160, 16)
	$UI.prog3.Visible = $false
	$p3.Controls.Add($UI.prog3)
	$UI.lblCheckSum = & $mkLabel $p3 '' 370 8 400 24 $true 'Top,Left,Right'
	$UI.lvCheck = & $mkList $p3 0 44 780 370 @('p_col0', 'p_col1', 'p_col2', 'p_col3') @(80, 220, 250, 220)
	$UI.lvCheck.ShowGroups = $true
	$UI.lblCheckMsg = & $mkLabel $p3 '' 0 424 780 22 $false 'Left,Right,Bottom'
	$UI.chkAck = New-Object System.Windows.Forms.CheckBox
	$UI.chkAck.Location = New-Object System.Drawing.Point(0, 452)
	$UI.chkAck.Size = New-Object System.Drawing.Size(700, 24)
	$UI.chkAck.Anchor = 'Left,Bottom'
	$UI.chkAck.Enabled = $false
	$p3.Controls.Add($UI.chkAck)
	& $Reg $UI.chkAck 'p_ack'

	# ---------- Seite 4: Zusammenfassung ----------
	$p4 = & $mkPage
	$Pages[4] = $p4
	$UI.lPlan = & $mkLabel $p4 'u_plan' 0 4 400 22 $true
	$UI.txtPlan = & $mkMulti $p4 0 28 780 150
	$UI.txtPlan.Anchor = 'Top,Left,Right'
	$UI.lSql = & $mkLabel $p4 'u_sqlprev' 0 188 600 22 $true
	$UI.txtSql = & $mkMulti $p4 0 212 780 120 $true
	$UI.btnCopySql = & $mkButton $p4 'u_copy' 0 338 160
	$UI.btnDry = & $mkButton $p4 'u_dry' 172 338 200
	$UI.lblDry = & $mkLabel $p4 '' 0 374 780 44 $false 'Top,Left,Right'
	$UI.lConfirm = & $mkLabel $p4 'u_confirm' 0 424 600 20
	$UI.txtConfirm = & $mkText $p4 0 446 380 'Top,Left'
	$UI.lblConfirmErr = & $mkLabel $p4 '' 392 449 360 20
	$UI.lblConfirmErr.ForeColor = $cErr

	# ---------- Seite 5: Ausfuehrung ----------
	$p5 = & $mkPage
	$Pages[5] = $p5
	$UI.lvRun = & $mkList $p5 0 4 780 200 @('x_step', 'x_state', 'x_detail') @(300, 110, 340)
	$UI.prog5 = New-Object System.Windows.Forms.ProgressBar
	$UI.prog5.Style = 'Marquee'
	$UI.prog5.MarqueeAnimationSpeed = 30
	$UI.prog5.Location = New-Object System.Drawing.Point(0, 212)
	$UI.prog5.Size = New-Object System.Drawing.Size(780, 12)
	$UI.prog5.Anchor = 'Top,Left,Right'
	$UI.prog5.Visible = $false
	$p5.Controls.Add($UI.prog5)
	$UI.lblRun = & $mkLabel $p5 '' 0 232 780 24 $true 'Top,Left,Right'
	$UI.pnlErr = New-Object System.Windows.Forms.Panel
	$UI.pnlErr.Location = New-Object System.Drawing.Point(0, 262)
	$UI.pnlErr.Size = New-Object System.Drawing.Size(780, 190)
	$UI.pnlErr.Anchor = 'Top,Left,Right'
	$UI.pnlErr.BackColor = [System.Drawing.Color]::FromArgb(253, 243, 242)
	$UI.pnlErr.Visible = $false
	$p5.Controls.Add($UI.pnlErr)
	$UI.lErrCause = & $mkLabel $UI.pnlErr 'x_cause' 10 8 120 20 $true
	$UI.lblErrCause = & $mkLabel $UI.pnlErr '' 134 8 630 36 $false 'Top,Left,Right'
	$UI.lErrFix = & $mkLabel $UI.pnlErr 'x_fix' 10 46 120 20 $true
	$UI.lblErrFix = & $mkLabel $UI.pnlErr '' 134 46 630 36 $false 'Top,Left,Right'
	$UI.lErrRaw = & $mkLabel $UI.pnlErr 'x_raw' 10 86 160 20 $true
	$UI.txtErrRaw = New-Object System.Windows.Forms.TextBox
	$UI.txtErrRaw.Multiline = $true
	$UI.txtErrRaw.ReadOnly = $true
	$UI.txtErrRaw.ScrollBars = 'Vertical'
	$UI.txtErrRaw.Font = $fMono
	$UI.txtErrRaw.Location = New-Object System.Drawing.Point(10, 108)
	$UI.txtErrRaw.Size = New-Object System.Drawing.Size(760, 42)
	$UI.txtErrRaw.Anchor = 'Top,Left,Right'
	$UI.pnlErr.Controls.Add($UI.txtErrRaw)
	$UI.btnRetry = & $mkButton $UI.pnlErr 'x_retry' 10 154 140 $true
	$UI.btnSkip = & $mkButton $UI.pnlErr 'x_skipbtn' 160 154 140
	$UI.btnAbort = & $mkButton $UI.pnlErr 'x_abort' 310 154 140

	# ---------- Seite 6: Synchronisation ----------
	$p6 = & $mkPage
	$Pages[6] = $p6
	$UI.lvSync = & $mkList $p6 0 4 780 300 @('y_db', 'y_state', 'y_health', 'y_send', 'y_redo', 'y_seed') @(190, 130, 100, 110, 110, 130)
	$UI.lblSyncState = & $mkLabel $p6 '' 0 314 780 44 $true 'Top,Left,Right'
	$UI.lblSyncPoll = & $mkLabel $p6 '' 0 362 600 20
	$UI.lblSyncPoll.ForeColor = $cDim
	$UI.btnRefresh = & $mkButton $p6 'y_refresh' 0 390 180

	# ---------- Seite 7: Listener ----------
	$p7 = & $mkPage
	$Pages[7] = $p7
	$UI.lLname = & $mkLabel $p7 'l_name' 0 4 200 20
	$UI.txtLname = & $mkText $p7 0 26 300 'Top,Left'
	$UI.lLport7 = & $mkLabel $p7 'l_port' 320 4 100 20
	$UI.txtLport7 = & $mkText $p7 320 26 100 'Top,Left'
	$UI.lA = & $mkLabel $p7 'l_a' 0 64 780 22 $true
	$UI.lAinfo = & $mkLabel $p7 'l_a_info' 0 88 780 36 $false 'Top,Left,Right'
	$UI.lAinfo.ForeColor = $cDim
	$UI.btnLA = & $mkButton $p7 'l_a_btn' 0 126 220 $true
	$UI.lblLA = & $mkLabel $p7 '' 232 132 540 22
	$UI.lB = & $mkLabel $p7 'l_b' 0 168 780 22 $true
	$UI.txtInstr = & $mkMulti $p7 0 192 780 112
	$UI.btnCopyInstr = & $mkButton $p7 'l_b_copy' 0 308 180
	$UI.lblWait = & $mkLabel $p7 '' 192 314 580 22
	$UI.chkSkipWait = New-Object System.Windows.Forms.CheckBox
	$UI.chkSkipWait.Location = New-Object System.Drawing.Point(0, 340)
	$UI.chkSkipWait.Size = New-Object System.Drawing.Size(760, 22)
	$p7.Controls.Add($UI.chkSkipWait)
	& $Reg $UI.chkSkipWait 'l_b_skipwait'
	$UI.chkTeam = New-Object System.Windows.Forms.CheckBox
	$UI.chkTeam.Location = New-Object System.Drawing.Point(0, 364)
	$UI.chkTeam.Size = New-Object System.Drawing.Size(770, 22)
	$p7.Controls.Add($UI.chkTeam)
	& $Reg $UI.chkTeam 'l_b_team'
	$UI.lC = & $mkLabel $p7 'l_c' 0 400 780 22 $true
	$UI.btnLC = & $mkButton $p7 'l_c_btn' 0 426 220 $true
	$UI.lblLC = & $mkLabel $p7 '' 232 432 540 22
	$UI.chkNoListener = New-Object System.Windows.Forms.CheckBox
	$UI.chkNoListener.Location = New-Object System.Drawing.Point(0, 466)
	$UI.chkNoListener.Size = New-Object System.Drawing.Size(770, 22)
	$p7.Controls.Add($UI.chkNoListener)
	& $Reg $UI.chkNoListener 'l_skip'

	# ---------- Seite 8: Failover ----------
	$p8 = & $mkPage
	$Pages[8] = $p8
	$UI.lO = & $mkLabel $p8 'o_state' 0 4 400 22 $true
	$UI.lblOState = & $mkLabel $p8 '' 0 28 780 44 $false 'Top,Left,Right'
	$UI.chkO1 = New-Object System.Windows.Forms.CheckBox
	$UI.chkO1.Location = New-Object System.Drawing.Point(0, 84)
	$UI.chkO1.Size = New-Object System.Drawing.Size(770, 24)
	$p8.Controls.Add($UI.chkO1)
	& $Reg $UI.chkO1 'o_check1'
	$UI.chkO2 = New-Object System.Windows.Forms.CheckBox
	$UI.chkO2.Location = New-Object System.Drawing.Point(0, 110)
	$UI.chkO2.Size = New-Object System.Drawing.Size(770, 24)
	$p8.Controls.Add($UI.chkO2)
	& $Reg $UI.chkO2 'o_check2'
	$UI.lOConfirm = & $mkLabel $p8 'o_confirm' 0 148 600 20
	$UI.txtOConfirm = & $mkText $p8 0 170 380 'Top,Left'
	$UI.btnFailover = & $mkButton $p8 'o_go' 0 208 240 $true
	$UI.btnRollback = & $mkButton $p8 'o_rb' 252 208 240
	$UI.btnRollback.Visible = $false
	$UI.lvFo = & $mkList $p8 0 252 780 160 @('x_step', 'x_state', 'x_detail') @(300, 110, 340)
	$UI.lblFo = & $mkLabel $p8 '' 0 420 780 40 $true 'Top,Left,Right'

	# ---------- Seite 9: Abschluss ----------
	$p9 = & $mkPage
	$Pages[9] = $p9
	$UI.lblDone = & $mkLabel $p9 '' 0 4 780 90 $false 'Top,Left,Right'
	$UI.lblDone.Font = $fBold
	$UI.lZ = & $mkLabel $p9 'z_clean' 0 104 780 22 $true
	$UI.lblZNote = & $mkLabel $p9 'z_note' 0 128 780 80 $false 'Top,Left,Right'
	$UI.txtClean = & $mkMulti $p9 0 214 780 100 $true
	$UI.btnCopyClean = & $mkButton $p9 'z_copy' 0 322 220
	$UI.btnOpenRep = & $mkButton $p9 'z_openrep' 232 322 220
	$UI.lblRbHint = & $mkLabel $p9 'z_rollbackhint' 0 362 780 22
	$UI.lblRbHint.ForeColor = $cDim

	# =====================================================================
	# Navigation
	# =====================================================================
	$RefreshSteps = {
		$curId = & $Cur
		for ($i = 0; $i -lt 10; $i++)
		{
			$l = $stepLabels[$i]
			$inFlow = ($S.Flow -contains $i)
			$l.Visible = $inFlow
			if (-not $inFlow) { continue }
			$pos = [array]::IndexOf($S.Flow, $i)
			$name = & $Tr "s$i"
			if ($i -eq $curId)
			{
				$l.Text = ([string][char]0x25CF) + '  ' + $name
				$l.Font = $fBold
				$l.ForeColor = $cAccent
				$l.BackColor = [System.Drawing.Color]::FromArgb(226, 235, 245)
			}
			elseif ($pos -lt $S.Page)
			{
				$l.Text = ([string][char]0x2713) + '  ' + $name
				$l.Font = $fBase
				$l.ForeColor = $cOk
				$l.BackColor = $cSide
			}
			else
			{
				$l.Text = ([string][char]0x25CB) + '  ' + $name
				$l.Font = $fBase
				$l.ForeColor = $cDim
				$l.BackColor = $cSide
			}
		}
	}

	$CanNext = {
		$i = & $Cur
		if ($S.Busy) { return $false }
		switch ($i)
		{
			0
			{
				if ($UI.rbResume.Checked) { return ($UI.cmbResume.SelectedIndex -ge 0 -and $UI.cmbResume.Enabled) }
				return $true
			}
			1 { return [bool]$S.Connected }
			2 { return [bool](& $ValidateConfig) }
			3
			{
				if (-not $S.PreflightRan -or $S.Blockers -gt 0) { return $false }
				if ($S.Warnings -gt 0 -and -not $UI.chkAck.Checked) { return $false }
				return $true
			}
			4 { return ([bool]$S.DryOk -or $true) -and ($UI.txtConfirm.Text.Trim() -eq [string]$S.Config.DistributedAgName) }
			5 { return ($S.UnitIndex -ge $S.Units.Count -and $S.Units.Count -ge 0 -and $S.Started -and -not $UI.pnlErr.Visible) }
			6 { return ([bool]$S.SyncReady -or $S.Mode -eq 'Ops') -and $true }
			7 { return ($UI.chkNoListener.Checked -or $S.ListenerC) }
			8 { return ($S.FailoverDone -and -not $S.RolledBack) }
			default { return $false }
		}
	}

	$UpdateNav = {
		$i = & $Cur
		$last = ($S.Page -ge ($S.Flow.Count - 1))
		$btnBack.Enabled = ($S.Page -gt 0 -and -not $S.Busy -and $i -notin 5, 6, 7, 8, 9 -and -not ($S.Started))
		if ($S.Started -and $i -in 6, 7) { $btnBack.Enabled = $false }
		$btnNext.Visible = (-not $last)
		$btnNext.Text = $(if ($i -eq 4) { (& $Tr 'start') } else { (& $Tr 'next') })
		$btnNext.Enabled = (& $CanNext)
		$btnCancel.Text = $(if ($last) { (& $Tr 'close') } else { (& $Tr 'cancel') })
		$btnCancel.Enabled = $true
		& $RefreshSteps
		$form.Cursor = $(if ($S.Busy) { [System.Windows.Forms.Cursors]::AppStarting } else { [System.Windows.Forms.Cursors]::Default })
	}

	$ShowPage = {
		$i = & $Cur
		foreach ($k in $Pages.Keys) { $Pages[$k].Visible = ($k -eq $i) }
		$lblTitle.Text = (& $Tr "h$i")
		$lblSub.Text = (& $Tr "h$($i)s")
		$S.StatePage = [math]::Max($S.StatePage, $i)
		& $UpdateNav
		& $OnEnter $i
		& $UpdateNav
	}
	$Go = {
		param ([int]$pos)
		$S.Page = [math]::Max(0, [math]::Min($pos, $S.Flow.Count - 1))
		& $ShowPage
	}

	$ApplyLang = {
		foreach ($entry in $S.Texts)
		{
			try { $entry.C.Text = (& $Tr $entry.K) } catch { Write-Verbose $_.Exception.Message }
		}
		$form.Text = (& $Tr 'title')
		$btnLang.Text = $(if ($S.Lang -eq 'de') { 'English' } else { 'Deutsch' })
		$btnLog.Text = $(if ($pnlLog.Height -gt 0 -or $tbl.RowStyles[2].Height -gt 0) { (& $Tr 'hidelog') } else { (& $Tr 'showlog') })
		$statusLbl.Text = (& $Tr 'ready')
		$UI.diagram.Invalidate()
		$lblTitle.Text = (& $Tr "h$(& $Cur)")
		$lblSub.Text = (& $Tr "h$(& $Cur)s")
		& $UpdateNav
		& $RenderDynamic
	}

	# =====================================================================
	# Validierung der Konfigurationsseite
	# =====================================================================
	$ValidateConfig = {
		$ok = $true
		$lang = $S.Lang
		$checks = @(
			@($UI.txtDagName, 'DagName', $true),
			@($UI.txtPort, 'Port', $true),
			@($UI.txtSrcFqdn, 'Fqdn', $true),
			@($UI.txtTgtFqdn, 'Fqdn', $true),
			@($UI.txtAcct, 'ServiceAccount', ($UI.txtAcct.Text.Trim().Length -gt 0)),
			@($UI.txtBak, 'Path', $UI.rbManual.Checked),
			@($UI.txtOut, 'Path', $true)
		)
		foreach ($c in $checks)
		{
			$ctl = $c[0]
			$msg = $null
			if ($c[2]) { $msg = Test-sqmDagInputValue -Kind $c[1] -Value $ctl.Text -Lang $lang }
			$ep.SetError($ctl, [string]$msg)
			if ($msg) { $ok = $false }
		}
		# Port der Listener-Seite und optionaler Listener-Name
		$lmsg = $null
		if ($UI.txtListener.Text.Trim().Length -gt 0 -and $UI.txtListener.Text -notmatch '^[A-Za-z0-9\-_\.]{1,63}$')
		{ $lmsg = $(if ($lang -eq 'de') { 'Ungültiger DNS-Name.' } else { 'Invalid DNS name.' }) }
		$ep.SetError($UI.txtListener, [string]$lmsg)
		if ($lmsg) { $ok = $false }
		$pmsg = Test-sqmDagInputValue -Kind Port -Value $UI.txtLport.Text -Lang $lang
		if ($UI.txtLport.Text -match '^\d+$' -and [int]$UI.txtLport.Text -ge 1 -and [int]$UI.txtLport.Text -le 65535) { $pmsg = $null }
		$ep.SetError($UI.txtLport, [string]$pmsg)
		if ($pmsg) { $ok = $false }
		return $ok
	}

	# =====================================================================
	# Konfiguration einsammeln
	# =====================================================================
	$CollectConfig = {
		$cfg = @{
			SourceInstance = $UI.txtSrcInst.Text.Trim(); TargetInstance = $UI.txtTgtInst.Text.Trim()
			SourceAgName = $(if ($S.Mode -eq 'Ops') { '' } else { [string]$UI.cmbSrcAg.SelectedItem })
			TargetAgName = $(if ($S.Mode -eq 'Ops') { '' } else { [string]$UI.cmbTgtAg.SelectedItem })
			DistributedAgName = $UI.txtDagName.Text.Trim()
			SourceFqdn = $UI.txtSrcFqdn.Text.Trim(); TargetFqdn = $UI.txtTgtFqdn.Text.Trim()
			EndpointPort = $(if ($UI.txtPort.Text -match '^\d+$') { [int]$UI.txtPort.Text } else { 5022 })
			ServiceAccount = $UI.txtAcct.Text.Trim()
			SeedingMode = $(if ($UI.rbManual.Checked) { 'Manual' } else { 'Automatic' })
			BackupPath = $UI.txtBak.Text.Trim()
			OutputPath = $UI.txtOut.Text.Trim()
			ListenerName = $UI.txtListener.Text.Trim()
			ListenerPort = $(if ($UI.txtLport.Text -match '^\d+$') { [int]$UI.txtLport.Text } else { 1433 })
		}
		if ($S.Mode -eq 'Ops') { $cfg.DistributedAgName = [string]$UI.cmbDag.SelectedItem }
		$base = if ($cfg.OutputPath) { $cfg.OutputPath } else { (Get-sqmDefaultOutputPath) }
		$cfg.ListenerOutputPath = (Join-Path $base 'ListenerMigration')
		$cfg.FailoverOutputPath = (Join-Path $base 'DistributedFailover')
		$S.Config = $cfg
		$S.ReportDir = $base
	}

	$ConnSignature = {
		return ("{0}|{1}|{2}|{3}|{4}|{5}" -f $UI.txtSrcInst.Text.Trim(), $UI.txtTgtInst.Text.Trim(), $UI.rbSql.Checked, $UI.txtUser.Text.Trim(), $UI.txtPwd.Text.Length, $S.Mode)
	}

	# =====================================================================
	# Dynamische Inhalte (sprachabhaengig)
	# =====================================================================
	$PlanText = {
		$c = $S.Config
		$lines = [System.Collections.Generic.List[string]]::new()
		$de = ($S.Lang -eq 'de')
		$lines.Add($(if ($de) { "Quelle: $($c.SourceInstance), AG [$($c.SourceAgName)]" } else { "Source: $($c.SourceInstance), AG [$($c.SourceAgName)]" }))
		$lines.Add($(if ($de) { "Ziel: $($c.TargetInstance), AG [$($c.TargetAgName)]" } else { "Target: $($c.TargetInstance), AG [$($c.TargetAgName)]" }))
		$lines.Add('')
		$lines.Add($(if ($de) { "1. Distributed AG [$($c.DistributedAgName)] auf der Quelle anlegen und die Ziel-AG anbinden (Seeding: $($c.SeedingMode), Endpoint-Port $($c.EndpointPort))." } else { "1. Create Distributed AG [$($c.DistributedAgName)] on the source and join the target AG (seeding: $($c.SeedingMode), endpoint port $($c.EndpointPort))." }))
		$n = 2
		if ($c.SeedingMode -eq 'Manual')
		{
			$lines.Add($(if ($de) { "$n. $($S.DbList.Count) Datenbank(en) per Backup/Restore über [$($c.BackupPath)] übertragen und der Ziel-AG hinzufügen." } else { "$n. Transfer $($S.DbList.Count) database(s) by backup/restore via [$($c.BackupPath)] and add them to the target AG." }))
		}
		else
		{
			$lines.Add($(if ($de) { "$n. $($S.DbList.Count) Datenbank(en) werden von SQL Server automatisch auf die Ziel-AG übertragen (Autoseed)." } else { "$n. $($S.DbList.Count) database(s) are transferred to the target AG automatically by SQL Server (autoseed)." }))
		}
		$n++
		$lines.Add($(if ($de) { "$n. Synchronisation überwachen, bis alle Datenbanken bereit sind." } else { "$n. Monitor synchronization until all databases are ready." })); $n++
		$lines.Add($(if ($de) { "$n. Listener auf den neuen Cluster umziehen (mit Cluster-/AD-Team)." } else { "$n. Move the listener to the new cluster (with the cluster/AD team)." })); $n++
		$lines.Add($(if ($de) { "$n. Geplantes Failover auf den neuen Cluster. Rollback bleibt möglich." } else { "$n. Planned failover to the new cluster. Rollback stays possible." }))
		return ($lines -join "`r`n")
	}
	$SqlPreview = {
		$c = $S.Config
		$mode = if ($c.SeedingMode -eq 'Manual') { 'MANUAL' } else { 'AUTOMATIC' }
		$sb = [System.Text.StringBuilder]::new()
		[void]$sb.AppendLine("-- auf [$($c.SourceInstance)]")
		[void]$sb.AppendLine("CREATE AVAILABILITY GROUP [$($c.DistributedAgName)] WITH (DISTRIBUTED)")
		[void]$sb.AppendLine("AVAILABILITY GROUP ON")
		[void]$sb.AppendLine("  N'$($c.SourceAgName)' WITH (LISTENER_URL = N'TCP://$($c.SourceFqdn):$($c.EndpointPort)', AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = $mode),")
		[void]$sb.AppendLine("  N'$($c.TargetAgName)' WITH (LISTENER_URL = N'TCP://$($c.TargetFqdn):$($c.EndpointPort)', AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = $mode);")
		[void]$sb.AppendLine('')
		[void]$sb.AppendLine("-- auf [$($c.TargetInstance)]")
		if ($mode -eq 'AUTOMATIC') { [void]$sb.AppendLine("ALTER AVAILABILITY GROUP [$($c.TargetAgName)] GRANT CREATE ANY DATABASE;") }
		[void]$sb.AppendLine("ALTER AVAILABILITY GROUP [$($c.DistributedAgName)] JOIN AVAILABILITY GROUP ON")
		[void]$sb.AppendLine("  N'$($c.SourceAgName)' WITH (LISTENER_URL = N'TCP://$($c.SourceFqdn):$($c.EndpointPort)', AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = $mode),")
		[void]$sb.AppendLine("  N'$($c.TargetAgName)' WITH (LISTENER_URL = N'TCP://$($c.TargetFqdn):$($c.EndpointPort)', AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = $mode);")
		return $sb.ToString()
	}
	$CleanSql = {
		$c = $S.Config
		return ("-- nach erfolgreicher Migration, auf BEIDEN Clustern (jeweils auf dem Primary der AG)`r`nDROP AVAILABILITY GROUP [$($c.DistributedAgName)];")
	}

	$FillCheckList = {
		$UI.lvCheck.BeginUpdate()
		$UI.lvCheck.Items.Clear()
		$UI.lvCheck.Groups.Clear()
		$de = ($S.Lang -eq 'de')
		$groups = @{ }
		if ($S.Checks)
		{
			foreach ($ck in $S.Checks.Checks)
			{
				if (-not $groups.ContainsKey($ck.Category))
				{
					$g = New-Object System.Windows.Forms.ListViewGroup($ck.Category, $ck.Category)
					[void]$UI.lvCheck.Groups.Add($g)
					$groups[$ck.Category] = $g
				}
				$stTxt = switch ($ck.Status) { 'Pass' { & $Tr 'p_ok' } 'Warn' { & $Tr 'p_warn' } default { & $Tr 'p_fail' } }
				$msg = if ($de) { $ck.MessageDe } else { $ck.MessageEn }
				$fix = if ($de) { $ck.RemedyDe } else { $ck.RemedyEn }
				$it = New-Object System.Windows.Forms.ListViewItem($stTxt)
				[void]$it.SubItems.Add([string]$ck.Name)
				[void]$it.SubItems.Add([string]$msg)
				[void]$it.SubItems.Add([string]$fix)
				$it.Group = $groups[$ck.Category]
				$it.ForeColor = switch ($ck.Status) { 'Pass' { $cOk } 'Warn' { $cWarn } default { $cErr } }
				[void]$UI.lvCheck.Items.Add($it)
			}
		}
		$UI.lvCheck.EndUpdate()
		if ($S.Checks)
		{
			$UI.lblCheckSum.Text = (& $Tr 'p_sum' @($S.Checks.Passed, $S.Checks.Warnings.Count, $S.Checks.Blockers.Count))
			$UI.lblCheckSum.ForeColor = $(if ($S.Blockers -gt 0) { $cErr } elseif ($S.Warnings -gt 0) { $cWarn } else { $cOk })
			$UI.lblCheckMsg.Text = $(if ($S.Blockers -gt 0) { (& $Tr 'p_fixfirst') } elseif ($S.Warnings -eq 0) { (& $Tr 'p_clean') } else { '' })
			$UI.lblCheckMsg.ForeColor = $(if ($S.Blockers -gt 0) { $cErr } else { $cOk })
		}
	}

	$SetRunRow = {
		param ([int]$idx, [string]$state, [string]$detail)
		if ($idx -lt 0 -or $idx -ge $UI.lvRun.Items.Count) { return }
		$it = $UI.lvRun.Items[$idx]
		$txt = switch ($state) { 'run' { & $Tr 'x_run' } 'done' { & $Tr 'x_done' } 'skip' { & $Tr 'x_skip' } 'fail' { & $Tr 'x_fail' } default { & $Tr 'x_wait' } }
		$it.SubItems[1].Text = $txt
		if ($detail) { $it.SubItems[2].Text = $detail }
		$it.ForeColor = switch ($state) { 'done' { $cOk } 'skip' { $cDim } 'fail' { $cErr } 'run' { $cAccent } default { $cText } }
	}

	$RenderDynamic = {
		$i = & $Cur
		if ($S.Checks -and $i -eq 3) { & $FillCheckList }
		if ($i -eq 4 -and $S.Config.DistributedAgName)
		{
			$UI.txtPlan.Text = (& $PlanText)
			$UI.txtSql.Text = (& $SqlPreview)
		}
		if ($i -eq 7 -and $S.ListenerInfo) { & $RenderInstruction }
		if ($i -eq 9) { & $RenderDone }
	}

	$RenderInstruction = {
		$c = $S.Config
		$li = $S.ListenerInfo
		$ip = if ($li -and $li.ListenerIp) { [string]$li.ListenerIp } else { '-' }
		$UI.txtInstr.Text = (& $Tr 'l_instr' @($c.TargetAgName, $UI.txtLname.Text, $UI.txtLport7.Text, $ip))
	}
	$RenderDone = {
		$c = $S.Config
		$de = ($S.Lang -eq 'de')
		$t = if ($S.RolledBack) { if ($de) { "Die Migration wurde zurückgerollt. Der alte Cluster ist wieder Primary der Distributed AG [$($c.DistributedAgName)]." } else { "The migration was rolled back. The old cluster is primary of the Distributed AG [$($c.DistributedAgName)] again." } }
		elseif ($S.FailoverDone) { if ($de) { "Die Migration ist abgeschlossen. Der neue Cluster [$($c.TargetInstance)] ist jetzt Primary der Distributed AG [$($c.DistributedAgName)]." } else { "The migration is complete. The new cluster [$($c.TargetInstance)] is now primary of the Distributed AG [$($c.DistributedAgName)]." } }
		else { if ($de) { 'Betrieb: keine Änderung durchgeführt.' } else { 'Operations: no change made.' } }
		$UI.lblDone.Text = $t
		$UI.txtClean.Text = (& $CleanSql)
	}

	# =====================================================================
	# Seitenwechsel-Logik (Betreten)
	# =====================================================================
	$LoadResumeList = {
		$UI.cmbResume.Items.Clear()
		$S.ResumeStates = @()
		$a = @{ }
		if ($S.StateDir) { $a['BasePath'] = $S.StateDir }
		$states = @(Get-sqmDagMigrationState @a)
		foreach ($st in $states)
		{
			if ($st.Corrupt)
			{
				[void]$UI.cmbResume.Items.Add(([System.IO.Path]::GetFileName($st.StateFile) + ' ' + (& $Tr 'w_corrupt')))
			}
			else
			{
				[void]$UI.cmbResume.Items.Add(("{0} -> {1}   ({2})" -f $st.SourceAgName, $st.TargetAgName, $st.SavedAt))
			}
		}
		$S.ResumeStates = $states
		$UI.rbResume.Enabled = ($states.Count -gt 0)
		$UI.lblNoResume.Text = $(if ($states.Count -eq 0) { (& $Tr 'w_noresume') } else { '' })
		if ($states.Count -gt 0 -and $UI.cmbResume.SelectedIndex -lt 0) { $UI.cmbResume.SelectedIndex = 0 }
	}

	$OnEnter = {
		param ([int]$i)
		switch ($i)
		{
			0 { & $LoadResumeList }
			1
			{
				$ops = ($S.Mode -eq 'Ops')
				$UI.lSrcAg.Visible = -not $ops; $UI.cmbSrcAg.Visible = -not $ops
				$UI.lTgtAg.Visible = -not $ops; $UI.cmbTgtAg.Visible = -not $ops
				$UI.lDag.Visible = $ops; $UI.cmbDag.Visible = $ops
				$UI.lSrcInst.Text = $(if ($ops) { $(if ($S.Lang -eq 'de') { 'Aktueller Primary (SQL-Instanz oder Listener)' } else { 'Current primary (SQL instance or listener)' }) } else { (& $Tr 'c_inst') })
			}
			2
			{
				$c = $S.Config
				if (-not $UI.txtDagName.Text.Trim())
				{
					$nm = "$($c.SourceAgName)_$($c.TargetAgName)"
					$UI.txtDagName.Text = $(if ($nm.Length -gt 128) { $nm.Substring(0, 128) } else { $nm })
				}
				if (-not $UI.txtSrcFqdn.Text.Trim() -and $S.SrcFqdn) { $UI.txtSrcFqdn.Text = $S.SrcFqdn }
				if (-not $UI.txtTgtFqdn.Text.Trim() -and $S.TgtFqdn) { $UI.txtTgtFqdn.Text = $S.TgtFqdn }
				if (-not $UI.txtOut.Text.Trim()) { $UI.txtOut.Text = (Get-sqmDefaultOutputPath) }
				[void](& $ValidateConfig)
			}
			3
			{
				if (-not $S.PreflightRan -and -not $S.Busy) { $UI.btnCheck.PerformClick() }
				& $FillCheckList
			}
			4
			{
				$UI.txtPlan.Text = (& $PlanText)
				$UI.txtSql.Text = (& $SqlPreview)
				$UI.txtConfirm.Text = ''
			}
			5 { }
			6
			{
				& $PollSync
				$tmrSync.Start()
			}
			7
			{
				if (-not $UI.txtLname.Text.Trim()) { $UI.txtLname.Text = $S.Config.ListenerName }
				if (-not $UI.txtLport7.Text.Trim()) { $UI.txtLport7.Text = [string]$S.Config.ListenerPort }
				& $RenderInstruction
				& $UpdateListenerUi
			}
			8
			{
				$UI.txtOConfirm.Text = ''
				& $PollSync
				& $UpdateFailoverUi
			}
			9
			{
				$tmrSync.Stop()
				& $RenderDone
			}
		}
	}

	# =====================================================================
	# Jobs: Verbindung
	# =====================================================================
	$TestConnection = {
		$ep.Clear()
		$ok = $true
		$ma = Test-sqmDagInputValue -Kind Instance -Value $UI.txtSrcInst.Text -Lang $S.Lang
		$mb = Test-sqmDagInputValue -Kind Instance -Value $UI.txtTgtInst.Text -Lang $S.Lang
		if ($ma) { $ep.SetError($UI.txtSrcInst, $ma); $ok = $false }
		if ($mb) { $ep.SetError($UI.txtTgtInst, $mb); $ok = $false }
		if ($ok -and $UI.txtSrcInst.Text.Trim() -ieq $UI.txtTgtInst.Text.Trim())
		{
			$ep.SetError($UI.txtTgtInst, (& $Tr 'c_same')); $ok = $false
		}
		$cred = $null
		if ($UI.rbSql.Checked)
		{
			if (-not $UI.txtUser.Text.Trim()) { $ep.SetError($UI.txtUser, $(if ($S.Lang -eq 'de') { 'Pflichtfeld.' } else { 'Required.' })); $ok = $false }
			if (-not $UI.txtPwd.Text) { $ep.SetError($UI.txtPwd, $(if ($S.Lang -eq 'de') { 'Pflichtfeld.' } else { 'Required.' })); $ok = $false }
			if ($ok)
			{
				$sec = ConvertTo-SecureString -String $UI.txtPwd.Text -AsPlainText -Force
				$cred = New-Object System.Management.Automation.PSCredential($UI.txtUser.Text.Trim(), $sec)
			}
		}
		if (-not $ok) { return }
		$S.Cred = $cred
		$S.Connected = $false
		$UI.lblConn.Text = ''
		$UI.prog1.Visible = $true
		$UI.btnTest.Enabled = $false
		& $SetStatus (& $Tr 'busy')
		& $Log "Verbinde mit [$($UI.txtSrcInst.Text.Trim())] und [$($UI.txtTgtInst.Text.Trim())] ..."
		$code = @'
param($a, $b, $cred)
[PSCustomObject]@{ Src = (Get-sqmDagAgList -SqlInstance $a -SqlCredential $cred); Tgt = (Get-sqmDagAgList -SqlInstance $b -SqlCredential $cred) }
'@
		& $StartJob $code @($UI.txtSrcInst.Text.Trim(), $UI.txtTgtInst.Text.Trim(), $cred) $null {
			param ($r)
			$UI.prog1.Visible = $false
			$UI.btnTest.Enabled = $true
			& $SetStatus (& $Tr 'ready')
			$res = if ($r.Output) { $r.Output | Select-Object -First 1 } else { $null }
			if ($r.Failed -or -not $res)
			{
				$msg = if ($r.Errors) { ($r.Errors | ForEach-Object { $_.ToString() }) -join '; ' } else { 'Unbekannter Fehler' }
				$e = Resolve-sqmDagError -Message $msg
				$UI.lblConn.ForeColor = $cErr
				$UI.lblConn.Text = $(if ($S.Lang -eq 'de') { "$($e.CauseDe) $($e.FixDe)" } else { "$($e.CauseEn) $($e.FixEn)" })
				& $Log $msg 'ERROR'
				return
			}
			$lines = [System.Collections.Generic.List[string]]::new()
			$good = $true
			foreach ($side in @(@($res.Src, $UI.txtSrcInst, $UI.cmbSrcAg), @($res.Tgt, $UI.txtTgtInst, $UI.cmbTgtAg)))
			{
				$info = $side[0]; $txt = $side[1]; $cmb = $side[2]
				if (-not $info.Ok)
				{
					$good = $false
					$m = $(if ($S.Lang -eq 'de') { "$($info.Instance): $($info.Error.CauseDe) $($info.Error.FixDe)" } else { "$($info.Instance): $($info.Error.CauseEn) $($info.Error.FixEn)" })
					$lines.Add($m)
					$ep.SetError($txt, $(if ($S.Lang -eq 'de') { $info.Error.CauseDe } else { $info.Error.CauseEn }))
					& $Log "Verbindung zu [$($info.Instance)] fehlgeschlagen: $($info.Error.Raw)" 'ERROR'
					continue
				}
				if (-not $info.HadrEnabled) { $good = $false; $lines.Add("$($info.Instance): $(& $Tr 'c_nohadr')"); $ep.SetError($txt, (& $Tr 'c_nohadr')); continue }
				if (-not $info.IsSysadmin) { $good = $false; $lines.Add("$($info.Instance): $(& $Tr 'c_nosys')"); $ep.SetError($txt, (& $Tr 'c_nosys')); continue }
				$lines.Add((& $Tr 'c_ok' @($info.Instance, $info.ProductVersion, $info.AvailabilityGroups.Count)))
				& $Log "Verbunden: [$($info.Instance)] SQL $($info.ProductVersion), $($info.AvailabilityGroups.Count) Gruppe(n)" 'OK'
			}
			if ($good -and $S.Mode -ne 'Ops')
			{
				$S.AgRoles = @{ }
				foreach ($pair in @(@($res.Src, $UI.cmbSrcAg, 'src'), @($res.Tgt, $UI.cmbTgtAg, 'tgt')))
				{
					$info = $pair[0]; $cmb = $pair[1]
					$cmb.Items.Clear()
					foreach ($ag in $info.AvailabilityGroups) { [void]$cmb.Items.Add($ag.Name); $S.AgRoles["$($pair[2]):$($ag.Name)"] = $ag.Role }
					if ($info.AvailabilityGroups.Count -eq 0) { $good = $false; $lines.Add("$($info.Instance): $(& $Tr 'c_noag')"); $ep.SetError($(if ($pair[2] -eq 'src') { $UI.txtSrcInst } else { $UI.txtTgtInst }), (& $Tr 'c_noag')) }
					elseif ($cmb.Items.Count -ge 1)
					{
						$pref = $info.AvailabilityGroups | Where-Object { $_.Role -eq 'PRIMARY' } | Select-Object -First 1
						$cmb.SelectedItem = $(if ($pref) { $pref.Name } else { $info.AvailabilityGroups[0].Name })
					}
				}
			}
			if ($good -and $S.Mode -eq 'Ops')
			{
				$UI.cmbDag.Items.Clear()
				foreach ($d in $res.Src.DistributedAgs) { [void]$UI.cmbDag.Items.Add($d) }
				if ($UI.cmbDag.Items.Count -eq 0) { $good = $false; $lines.Add((& $Tr 'c_nodag')) } else { $UI.cmbDag.SelectedIndex = 0 }
			}
			$S.SrcFqdn = [string]$res.Src.Fqdn
			$S.TgtFqdn = [string]$res.Tgt.Fqdn
			$UI.lblConn.ForeColor = $(if ($good) { $cOk } else { $cErr })
			$UI.lblConn.Text = ($lines -join "`r`n")
			if ($good)
			{
				$S.Connected = $true
				$S.ConnSig = (& $ConnSignature)
			}
			& $UpdateNav
		}
	}

	# =====================================================================
	# Jobs: Vorabpruefung
	# =====================================================================
	$RunPreflight = {
		& $CollectConfig
		$c = $S.Config
		$S.PreflightRan = $false
		$S.Checks = $null
		$UI.chkAck.Checked = $false
		$UI.chkAck.Enabled = $false
		$UI.lvCheck.Items.Clear()
		$UI.lblCheckSum.Text = (& $Tr 'p_running')
		$UI.lblCheckSum.ForeColor = $cDim
		$UI.lblCheckMsg.Text = ''
		$UI.prog3.Visible = $true
		$UI.btnCheck.Enabled = $false
		& $Log 'Starte Vorabprüfung ...'
		$code = @'
param($c, $cred)
$p = @{ SourceInstance = $c.SourceInstance; SourceAgName = $c.SourceAgName; TargetInstance = $c.TargetInstance; TargetAgName = $c.TargetAgName
        DistributedAgName = $c.DistributedAgName; SourceFqdn = $c.SourceFqdn; TargetFqdn = $c.TargetFqdn; EndpointPort = [int]$c.EndpointPort; SeedingMode = $c.SeedingMode }
if ($c.BackupPath) { $p['BackupPath'] = $c.BackupPath }
if ($cred) { $p['SqlCredential'] = $cred }
Test-sqmDistributedAgMigrationPrerequisite @p
'@
		& $StartJob $code @($c, $S.Cred) $null {
			param ($r)
			$UI.prog3.Visible = $false
			$UI.btnCheck.Enabled = $true
			$res = if ($r.Output) { $r.Output | Select-Object -First 1 } else { $null }
			if ($r.Failed -or -not $res)
			{
				$msg = if ($r.Errors) { ($r.Errors | ForEach-Object { $_.ToString() }) -join '; ' } else { 'Unbekannter Fehler' }
				$e = Resolve-sqmDagError -Message $msg
				$UI.lblCheckSum.Text = $(if ($S.Lang -eq 'de') { $e.CauseDe } else { $e.CauseEn })
				$UI.lblCheckSum.ForeColor = $cErr
				$UI.lblCheckMsg.Text = $(if ($S.Lang -eq 'de') { $e.FixDe } else { $e.FixEn })
				& $Log $msg 'ERROR'
				return
			}
			$S.Checks = $res
			$S.PreflightRan = $true
			$S.Blockers = $res.Blockers.Count
			$S.Warnings = $res.Warnings.Count
			$S.DbList = @($res.SourceDatabases)
			$UI.chkAck.Enabled = ($S.Warnings -gt 0 -and $S.Blockers -eq 0)
			& $FillCheckList
			& $Log ("Vorabprüfung: {0} bestanden, {1} Warnung(en), {2} Fehler" -f $res.Passed, $S.Warnings, $S.Blockers) $(if ($S.Blockers -gt 0) { 'ERROR' } elseif ($S.Warnings -gt 0) { 'WARN' } else { 'OK' })
			& $UpdateNav
		}
	}

	# =====================================================================
	# Trockenlauf
	# =====================================================================
	$RunDry = {
		& $CollectConfig
		$UI.lblDry.Text = (& $Tr 'busy')
		$UI.lblDry.ForeColor = $cDim
		$UI.btnDry.Enabled = $false
		& $Log 'Trockenlauf (WhatIf) ...'
		$code = @'
param($c, $cred)
Invoke-sqmDagMigrationUnit -Unit CreateDag -Config $c -SqlCredential $cred -DryRun
'@
		& $StartJob $code @($S.Config, $S.Cred) $null {
			param ($r)
			$UI.btnDry.Enabled = $true
			$res = if ($r.Output) { $r.Output | Select-Object -First 1 } else { $null }
			if ($res -and $res.Ok)
			{
				$S.DryOk = $true
				$UI.lblDry.ForeColor = $cOk
				$UI.lblDry.Text = (& $Tr 'u_dryok' @($res.Status))
				& $Log 'Trockenlauf erfolgreich.' 'OK'
			}
			else
			{
				$S.DryOk = $false
				$raw = if ($res -and $res.Error) { $res.Error.Raw } elseif ($r.Errors) { ($r.Errors | ForEach-Object { $_.ToString() }) -join '; ' } else { '' }
				$UI.lblDry.ForeColor = $cErr
				$UI.lblDry.Text = (& $Tr 'u_dryfail') + ' ' + $raw
				& $Log "Trockenlauf fehlgeschlagen: $raw" 'ERROR'
			}
			& $UpdateNav
		}
	}

	# =====================================================================
	# Ausfuehrung (Seite 5)
	# =====================================================================
	$BuildUnits = {
		$units = [System.Collections.Generic.List[hashtable]]::new()
		$units.Add(@{ Unit = 'CreateDag'; Db = ''; Title = (& $Tr 'x_dag') })
		if ($S.Config.SeedingMode -eq 'Manual')
		{
			foreach ($d in $S.DbList) { $units.Add(@{ Unit = 'AddDatabase'; Db = [string]$d; Title = (& $Tr 'x_db' @($d)) }) }
		}
		$S.Units = $units.ToArray()
		$UI.lvRun.Items.Clear()
		foreach ($u in $S.Units)
		{
			$it = New-Object System.Windows.Forms.ListViewItem($u.Title)
			[void]$it.SubItems.Add((& $Tr 'x_wait'))
			[void]$it.SubItems.Add('')
			[void]$UI.lvRun.Items.Add($it)
		}
	}

	$RunNextUnit = {
		if ($S.UnitIndex -ge $S.Units.Count)
		{
			$UI.prog5.Visible = $false
			$UI.lblRun.ForeColor = $cOk
			$UI.lblRun.Text = (& $Tr 'x_allok')
			& $SaveState
			& $UpdateNav
			& $SetStatus (& $Tr 'ready')
			return
		}
		$u = $S.Units[$S.UnitIndex]
		$idx = $S.UnitIndex
		$UI.pnlErr.Visible = $false
		$UI.prog5.Visible = $true
		$UI.lblRun.ForeColor = $cText
		$UI.lblRun.Text = $u.Title
		& $SetRunRow $idx 'run' ''
		& $Log "Ausführen: $($u.Title)"
		$code = @'
param($unit, $c, $cred, $db)
Invoke-sqmDagMigrationUnit -Unit $unit -Config $c -SqlCredential $cred -DatabaseName $db
'@
		& $StartJob $code @($u.Unit, $S.Config, $S.Cred, $u.Db) {
			param ($st)
			& $Log "  $($st.Step): $($st.Status)"
		} {
			param ($r)
			$res = if ($r.Output) { $r.Output | Select-Object -First 1 } else { $null }
			if ($res -and $res.Ok)
			{
				$detail = ''
				try { if ($res.Result.Steps) { $detail = (($res.Result.Steps | ForEach-Object { "$($_.Step): $($_.Status)" }) -join ', ') } } catch { Write-Verbose $_.Exception.Message }
				$allSkipped = $false
				try { $allSkipped = ($res.Result.Steps -and @($res.Result.Steps | Where-Object { $_.Status -ne 'SKIPPED' }).Count -eq 0) } catch { Write-Verbose $_.Exception.Message }
				& $SetRunRow $idx $(if ($allSkipped) { 'skip' } else { 'done' }) $detail
				$S.UnitDone["$($S.Units[$idx].Unit):$($S.Units[$idx].Db)"] = $true
				$S.UnitIndex = $idx + 1
				& $Log "Fertig: $($S.Units[$idx].Title)" 'OK'
				& $SaveState
				& $RunNextUnit
			}
			else
			{
				$e = if ($res -and $res.Error) { $res.Error } else { Resolve-sqmDagError -Message $(if ($r.Errors) { ($r.Errors | ForEach-Object { $_.ToString() }) -join '; ' } else { 'Unbekannter Fehler' }) }
				& $SetRunRow $idx 'fail' ''
				$UI.prog5.Visible = $false
				$UI.lblErrCause.Text = $(if ($S.Lang -eq 'de') { $e.CauseDe } else { $e.CauseEn })
				$UI.lblErrFix.Text = $(if ($S.Lang -eq 'de') { $e.FixDe } else { $e.FixEn })
				$UI.txtErrRaw.Text = [string]$e.Raw
				$UI.btnSkip.Visible = ($e.Category -eq 'AlreadyExists')
				$UI.pnlErr.Visible = $true
				$S.LastError = $e
				& $Log "Fehler bei '$($S.Units[$idx].Title)': $($e.Raw)" 'ERROR'
				& $SaveState
				& $UpdateNav
			}
		}
	}

	# =====================================================================
	# Synchronisation (Seite 6 und 8)
	# =====================================================================
	$PollSync = {
		if ($S.PJob) { return }
		if (-not $S.Config.DistributedAgName) { return }
		$code = @'
param($c, $cred)
$snap = $null; $seed = $null; $err = $null
try { $snap = @(Get-sqmDagSyncSnapshot -SqlInstance $c.SourceInstance -DagName $c.DistributedAgName -SqlCredential $cred) } catch { $err = $_.Exception.Message }
if ($c.SeedingMode -eq 'Automatic' -and -not $err) { try { $seed = @(Get-sqmDagSeedingSnapshot -SqlInstance $c.TargetInstance -SqlCredential $cred) } catch { $seed = $null } }
[PSCustomObject]@{ Snapshot = $snap; Seeding = $seed; Error = $err }
'@
		$S.PJob = Start-sqmDagBackgroundJob -Code $code -ArgumentList @($S.Config, $S.Cred)
		$tmr.Start()
	}
	$ApplySync = {
		param ($res)
		$S.LastPoll = Get-Date
		$UI.lblSyncPoll.Text = (& $Tr 'y_poll' @(("{0:HH:mm:ss}" -f $S.LastPoll)))
		if ($res.Error)
		{
			$e = Resolve-sqmDagError -Message $res.Error
			$UI.lblSyncState.ForeColor = $cErr
			$UI.lblSyncState.Text = (& $Tr 'y_err' @($(if ($S.Lang -eq 'de') { $e.CauseDe } else { $e.CauseEn })))
			$S.SyncReady = $false
			return
		}
		$snap = @($res.Snapshot)
		$UI.lvSync.BeginUpdate()
		$UI.lvSync.Items.Clear()
		foreach ($r in ($snap | Where-Object { -not ($_.IsLocal -eq $true -or $_.IsLocal -eq 1) }))
		{
			$seedTxt = ''
			if ($res.Seeding)
			{
				$sd = $res.Seeding | Where-Object { $_.DatabaseName -eq $r.DatabaseName } | Select-Object -First 1
				if ($sd) { $seedTxt = [string]$sd.State; if ($sd.FailureState -and $sd.FailureState -ne 'NoFailure' -and $sd.FailureState -ne 'None') { $seedTxt += " ($($sd.FailureState))" } }
			}
			$it = New-Object System.Windows.Forms.ListViewItem([string]$r.DatabaseName)
			[void]$it.SubItems.Add([string]$r.SyncState)
			[void]$it.SubItems.Add([string]$r.Health)
			[void]$it.SubItems.Add([string]$r.SendQueueKB)
			[void]$it.SubItems.Add([string]$r.RedoQueueKB)
			[void]$it.SubItems.Add($seedTxt)
			$it.ForeColor = $(if ($r.SyncState -in 'SYNCHRONIZED', 'SYNCHRONIZING' -and $r.Health -eq 'HEALTHY') { $cOk } else { $cWarn })
			[void]$UI.lvSync.Items.Add($it)
		}
		$UI.lvSync.EndUpdate()
		$ready = Test-sqmDagFailoverReady -Snapshot $snap
		$S.SyncReady = [bool]$ready.Ready
		$S.SyncReasons = ($ready.Reasons -join ' ')
		if ($ready.Ready)
		{
			$UI.lblSyncState.ForeColor = $cOk
			$UI.lblSyncState.Text = (& $Tr 'y_ready')
		}
		else
		{
			$UI.lblSyncState.ForeColor = $cWarn
			$UI.lblSyncState.Text = (& $Tr 'y_notready' @($S.SyncReasons))
		}
		& $UpdateFailoverUi
		& $UpdateNav
	}

	# =====================================================================
	# Listener (Seite 7)
	# =====================================================================
	$UpdateListenerUi = {
		$busy = $S.Busy
		$UI.btnLA.Enabled = (-not $busy -and -not $S.ListenerA -and -not $UI.chkNoListener.Checked)
		$UI.lblLA.Text = $(if ($S.ListenerA) { (& $Tr 'l_done') } else { '' })
		$UI.lblLA.ForeColor = $cOk
		$waitOver = $true
		if ($S.ListenerA -and $S.WaitUntil)
		{
			$left = $S.WaitUntil - (Get-Date)
			if ($left.TotalSeconds -gt 0)
			{
				$waitOver = $false
				$UI.lblWait.Text = (& $Tr 'l_b_wait' @(("{0:mm\:ss}" -f $left)))
				$UI.lblWait.ForeColor = $cWarn
			}
			else { $UI.lblWait.Text = (& $Tr 'l_b_waitdone'); $UI.lblWait.ForeColor = $cOk }
		}
		elseif (-not $S.ListenerA) { $UI.lblWait.Text = '' }
		$UI.chkSkipWait.Enabled = ($S.ListenerA -and -not $waitOver)
		$ready = ($S.ListenerA -and ($waitOver -or $UI.chkSkipWait.Checked))
		$UI.chkTeam.Enabled = $ready
		$UI.btnLC.Enabled = (-not $busy -and $ready -and $UI.chkTeam.Checked -and -not $S.ListenerC)
		$UI.lblLC.Text = $(if ($S.ListenerC) { (& $Tr 'l_done') } else { '' })
		$UI.lblLC.ForeColor = $cOk
		$UI.chkNoListener.Enabled = (-not $S.ListenerA -and -not $S.ListenerC -and -not $busy)
		& $UpdateNav
	}

	$RunListener = {
		param ([string]$unit)
		$S.Config.ListenerName = $UI.txtLname.Text.Trim()
		$S.Config.ListenerPort = $(if ($UI.txtLport7.Text -match '^\d+$') { [int]$UI.txtLport7.Text } else { 1433 })
		if ($unit -eq 'ListenerComplete' -and -not $S.Config.ListenerName)
		{
			[void][System.Windows.Forms.MessageBox]::Show($(if ($S.Lang -eq 'de') { 'Bitte den Listener-Namen eintragen.' } else { 'Please enter the listener name.' }), (& $Tr 'title'), 'OK', 'Information')
			return
		}
		& $Log "Listener-Schritt: $unit"
		$code = @'
param($unit, $c, $cred)
Invoke-sqmDagMigrationUnit -Unit $unit -Config $c -SqlCredential $cred
'@
		& $StartJob $code @($unit, $S.Config, $S.Cred) $null {
			param ($r)
			$res = if ($r.Output) { $r.Output | Select-Object -First 1 } else { $null }
			if ($res -and $res.Ok)
			{
				if ($unit -eq 'ListenerPrep')
				{
					$S.ListenerA = $true
					$S.WaitUntil = (Get-Date).AddMinutes(15)
					$tmrWait.Start()
					try
					{
						$S.ListenerInfo = $res.Result
						if ($res.Result.ListenerName -and -not $UI.txtLname.Text.Trim()) { $UI.txtLname.Text = [string]$res.Result.ListenerName }
					}
					catch { Write-Verbose $_.Exception.Message }
				}
				else { $S.ListenerC = $true }
				& $Log "Listener-Schritt erledigt: $unit" 'OK'
				& $SaveState
			}
			else
			{
				$e = if ($res -and $res.Error) { $res.Error } else { Resolve-sqmDagError -Message $(if ($r.Errors) { ($r.Errors | ForEach-Object { $_.ToString() }) -join '; ' } else { 'Unbekannter Fehler' }) }
				$txt = $(if ($S.Lang -eq 'de') { "$($e.CauseDe)`r`n$($e.FixDe)" } else { "$($e.CauseEn)`r`n$($e.FixEn)" })
				& $Log "$unit fehlgeschlagen: $($e.Raw)" 'ERROR'
				[void][System.Windows.Forms.MessageBox]::Show($txt + "`r`n`r`n" + $e.Raw, (& $Tr 'm_lerr'), 'OK', 'Warning')
			}
			& $RenderInstruction
			& $UpdateListenerUi
		}
	}

	# =====================================================================
	# Failover (Seite 8)
	# =====================================================================
	$UpdateFailoverUi = {
		if ((& $Cur) -ne 8) { return }
		$name = [string]$S.Config.DistributedAgName
		$typed = ($UI.txtOConfirm.Text.Trim() -eq $name -and $name)
		$UI.btnFailover.Enabled = (-not $S.Busy -and $S.SyncReady -and $UI.chkO1.Checked -and $UI.chkO2.Checked -and $typed -and -not ($S.FailoverDone -and -not $S.RolledBack))
		$UI.btnRollback.Visible = ($S.FailoverDone -and -not $S.RolledBack)
		$UI.btnRollback.Enabled = (-not $S.Busy)
		$UI.lblOState.Text = $(if ($S.SyncReady) { (& $Tr 'y_ready') } else { (& $Tr 'o_notready') + ' ' + $S.SyncReasons })
		$UI.lblOState.ForeColor = $(if ($S.SyncReady) { $cOk } else { $cWarn })
	}
	$RunFailover = {
		param ([string]$unit)
		$UI.lvFo.Items.Clear()
		$UI.lblFo.Text = (& $Tr 'busy')
		$UI.lblFo.ForeColor = $cDim
		& $Log "$unit startet ..." 'WARN'
		$code = @'
param($unit, $c, $cred)
Invoke-sqmDagMigrationUnit -Unit $unit -Config $c -SqlCredential $cred
'@
		& $StartJob $code @($unit, $S.Config, $S.Cred) {
			param ($st)
			$it = New-Object System.Windows.Forms.ListViewItem([string]$st.Step)
			[void]$it.SubItems.Add([string]$st.Status)
			[void]$it.SubItems.Add('')
			[void]$UI.lvFo.Items.Add($it)
			& $Log "  $($st.Step): $($st.Status)"
		} {
			param ($r)
			$res = if ($r.Output) { $r.Output | Select-Object -First 1 } else { $null }
			if ($res -and $res.Ok)
			{
				if ($unit -eq 'Failover') { $S.FailoverDone = $true; $S.RolledBack = $false; $UI.lblFo.Text = (& $Tr 'o_ok' @($res.Result.NewPrimaryAg)) }
				else { $S.RolledBack = $true; $UI.lblFo.Text = (& $Tr 'o_rbok' @($res.Result.NewPrimaryAg)) }
				$UI.lblFo.ForeColor = $cOk
				& $Log $UI.lblFo.Text 'OK'
				& $SaveState
			}
			else
			{
				$e = if ($res -and $res.Error) { $res.Error } else { Resolve-sqmDagError -Message $(if ($r.Errors) { ($r.Errors | ForEach-Object { $_.ToString() }) -join '; ' } else { 'Unbekannter Fehler' }) }
				$UI.lblFo.ForeColor = $cErr
				$UI.lblFo.Text = $(if ($S.Lang -eq 'de') { "$($e.CauseDe) $($e.FixDe)" } else { "$($e.CauseEn) $($e.FixEn)" }) + "`r`n" + $e.Raw
				& $Log "$unit fehlgeschlagen: $($e.Raw)" 'ERROR'
			}
			& $PollSync
			& $UpdateFailoverUi
		}
	}

	# =====================================================================
	# Ereignisse
	# =====================================================================
	$btnLang.Add_Click({ & $Guard { $S.Lang = $(if ($S.Lang -eq 'de') { 'en' } else { 'de' }); & $ApplyLang } })

	$btnLog.Add_Click({
			& $Guard {
				if ($tbl.RowStyles[2].Height -gt 0) { $tbl.RowStyles[2].Height = 0 } else { $tbl.RowStyles[2].Height = 170 }
				$btnLog.Text = $(if ($tbl.RowStyles[2].Height -gt 0) { (& $Tr 'hidelog') } else { (& $Tr 'showlog') })
			}
		})
	$btnSaveLog.Add_Click({
			& $Guard {
				$dlg = New-Object System.Windows.Forms.SaveFileDialog
				$dlg.Filter = 'Text (*.txt)|*.txt'
				$dlg.FileName = ("DistributedAgWizard-{0:yyyyMMdd-HHmmss}.txt" -f (Get-Date))
				if ($dlg.ShowDialog() -eq 'OK')
				{
					[System.IO.File]::WriteAllText($dlg.FileName, ($S.LogLines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
				}
			}
		})

	$UI.rbResume.Add_CheckedChanged({ & $Guard { $UI.cmbResume.Enabled = $UI.rbResume.Checked; & $UpdateNav } })
	$UI.cmbResume.Add_SelectedIndexChanged({ & $Guard { & $UpdateNav } })
	$UI.rbNew.Add_CheckedChanged({ & $Guard { & $UpdateNav } })
	$UI.rbOps.Add_CheckedChanged({ & $Guard { & $UpdateNav } })

	$invalidateConn = {
		& $Guard {
			if ($S.Connected -and $S.ConnSig -ne (& $ConnSignature))
			{
				$S.Connected = $false
				$UI.lblConn.Text = ''
			}
			& $UpdateNav
		}
	}
	foreach ($tbx in @($UI.txtSrcInst, $UI.txtTgtInst, $UI.txtUser, $UI.txtPwd)) { $tbx.Add_TextChanged($invalidateConn) }
	$UI.rbSql.Add_CheckedChanged({
			& $Guard {
				foreach ($x in @($UI.lUser, $UI.txtUser, $UI.lPwd, $UI.txtPwd)) { $x.Enabled = $UI.rbSql.Checked }
				& $invalidateConn
			}
		})
	$UI.btnTest.Add_Click({ & $Guard { & $TestConnection } })
	$UI.cmbSrcAg.Add_SelectedIndexChanged({
			& $Guard {
				$role = $S.AgRoles["src:$($UI.cmbSrcAg.SelectedItem)"]
				if ($role -and $role -ne 'PRIMARY') { $UI.lblConn.Text += "`r`n" + (& $Tr 'c_notpri' @($UI.txtSrcInst.Text)) }
				& $UpdateNav
			}
		})

	foreach ($tbx in @($UI.txtDagName, $UI.txtPort, $UI.txtSrcFqdn, $UI.txtTgtFqdn, $UI.txtAcct, $UI.txtBak, $UI.txtOut, $UI.txtListener, $UI.txtLport))
	{
		$tbx.Add_TextChanged({ & $Guard { [void](& $ValidateConfig); & $UpdateNav } })
	}
	$UI.rbManual.Add_CheckedChanged({ & $Guard { $UI.lBak.Enabled = $UI.rbManual.Checked; $UI.txtBak.Enabled = $UI.rbManual.Checked; [void](& $ValidateConfig); & $UpdateNav } })

	$UI.btnCheck.Add_Click({ & $Guard { & $RunPreflight } })
	$UI.chkAck.Add_CheckedChanged({ & $Guard { & $UpdateNav } })

	$UI.btnCopySql.Add_Click({ & $Guard { [System.Windows.Forms.Clipboard]::SetText($UI.txtSql.Text) } })
	$UI.btnDry.Add_Click({ & $Guard { & $RunDry } })
	$UI.txtConfirm.Add_TextChanged({
			& $Guard {
				$match = ($UI.txtConfirm.Text.Trim() -eq [string]$S.Config.DistributedAgName)
				$UI.lblConfirmErr.Text = $(if ($UI.txtConfirm.Text.Length -gt 0 -and -not $match) { (& $Tr 'u_mismatch') } else { '' })
				& $UpdateNav
			}
		})

	$UI.btnRetry.Add_Click({ & $Guard { & $RunNextUnit } })
	$UI.btnSkip.Add_Click({
			& $Guard {
				$idx = $S.UnitIndex
				& $SetRunRow $idx 'skip' ''
				$S.UnitDone["$($S.Units[$idx].Unit):$($S.Units[$idx].Db)"] = $true
				$S.UnitIndex = $idx + 1
				& $SaveState
				& $RunNextUnit
			}
		})
	$UI.btnAbort.Add_Click({
			& $Guard {
				$S.Aborted = $true
				$UI.pnlErr.Visible = $false
				$UI.lblRun.ForeColor = $cWarn
				$UI.lblRun.Text = (& $Tr 'x_aborted')
				$btnCancel.Text = (& $Tr 'close')
				& $SaveState
			}
		})

	$UI.btnRefresh.Add_Click({ & $Guard { & $PollSync } })
	$tmrSync.Add_Tick({ & $Guard { if ((& $Cur) -in 6, 8) { & $PollSync } } })

	$UI.btnLA.Add_Click({ & $Guard { & $RunListener 'ListenerPrep' } })
	$UI.btnLC.Add_Click({ & $Guard { & $RunListener 'ListenerComplete' } })
	$UI.btnCopyInstr.Add_Click({ & $Guard { [System.Windows.Forms.Clipboard]::SetText($UI.txtInstr.Text) } })
	$UI.chkSkipWait.Add_CheckedChanged({
			& $Guard {
				if ($UI.chkSkipWait.Checked)
				{
					$a = [System.Windows.Forms.MessageBox]::Show($(if ($S.Lang -eq 'de') { 'Wirklich überspringen? Anwendungen könnten noch auf den alten Listener zeigen.' } else { 'Really skip? Applications may still point to the old listener.' }), (& $Tr 'title'), 'YesNo', 'Warning')
					if ($a -ne 'Yes') { $UI.chkSkipWait.Checked = $false }
				}
				& $UpdateListenerUi
			}
		})
	$UI.chkTeam.Add_CheckedChanged({ & $Guard { & $UpdateListenerUi } })
	$UI.chkNoListener.Add_CheckedChanged({ & $Guard { & $UpdateListenerUi } })
	$UI.txtLname.Add_TextChanged({ & $Guard { & $RenderInstruction } })
	$tmrWait.Add_Tick({ & $Guard { if ((& $Cur) -eq 7) { & $UpdateListenerUi } } })

	foreach ($cb in @($UI.chkO1, $UI.chkO2)) { $cb.Add_CheckedChanged({ & $Guard { & $UpdateFailoverUi } }) }
	$UI.txtOConfirm.Add_TextChanged({ & $Guard { & $UpdateFailoverUi } })
	$UI.btnFailover.Add_Click({
			& $Guard {
				$a = [System.Windows.Forms.MessageBox]::Show($(if ($S.Lang -eq 'de') { 'Das Failover jetzt ausführen? Anwendungen verlieren kurz die Verbindung.' } else { 'Run the failover now? Applications briefly lose their connection.' }), (& $Tr 'title'), 'YesNo', 'Warning')
				if ($a -eq 'Yes') { & $RunFailover 'Failover' }
			}
		})
	$UI.btnRollback.Add_Click({
			& $Guard {
				$a = [System.Windows.Forms.MessageBox]::Show((& $Tr 'o_rbask'), (& $Tr 'title'), 'YesNo', 'Warning')
				if ($a -eq 'Yes') { & $RunFailover 'Rollback' }
			}
		})

	$UI.btnCopyClean.Add_Click({ & $Guard { [System.Windows.Forms.Clipboard]::SetText($UI.txtClean.Text) } })
	$UI.btnOpenRep.Add_Click({
			& $Guard {
				$d = if ($S.ReportDir) { $S.ReportDir } else { (Get-sqmDefaultOutputPath) }
				if (Test-Path -LiteralPath $d) { Start-Process explorer.exe -ArgumentList "`"$d`"" }
			}
		})

	# Timer: Hintergrundjobs abfragen
	$tmr.Add_Tick({
			& $Guard {
				if ($S.Job)
				{
					$r = Receive-sqmDagBackgroundJob -Job $S.Job
					foreach ($st in $r.Steps) { if ($S.OnStep) { & $S.OnStep $st } }
					if ($r.Done)
					{
						$job = $S.Job
						$S.Job = $null
						$S.Busy = $false
						$form.Cursor = [System.Windows.Forms.Cursors]::Default
						Remove-sqmDagBackgroundJob -Job $job
						$cb = $S.OnDone
						$S.OnDone = $null
						$S.OnStep = $null
						& $UpdateNav
						if ($cb) { & $cb $r }
						& $UpdateNav
					}
				}
				if ($S.PJob)
				{
					$pr = Receive-sqmDagBackgroundJob -Job $S.PJob
					if ($pr.Done)
					{
						$pj = $S.PJob
						$S.PJob = $null
						Remove-sqmDagBackgroundJob -Job $pj
						$out = if ($pr.Output) { $pr.Output | Select-Object -First 1 } else { $null }
						if ($out) { & $ApplySync $out }
						elseif ($pr.Errors)
						{
							& $ApplySync ([PSCustomObject]@{ Snapshot = @(); Seeding = $null; Error = (($pr.Errors | ForEach-Object { $_.ToString() }) -join '; ') })
						}
					}
				}
				if (-not $S.Job -and -not $S.PJob) { $tmr.Stop() }
			}
		})

	# =====================================================================
	# Weiter / Zurueck / Abbrechen
	# =====================================================================
	$AcquireLock = {
		if ($S.Mode -ne 'New' -or $S.Lock -or -not $S.Config.SourceAgName) { return $true }
		$a = @{ SourceAgName = $S.Config.SourceAgName; TargetAgName = $S.Config.TargetAgName }
		if ($S.StateDir) { $a['BasePath'] = $S.StateDir }
		$lk = Enter-sqmDagMigrationLock @a
		if (-not $lk.Acquired)
		{
			[void][System.Windows.Forms.MessageBox]::Show((& $Tr 'c_locked' @($lk.OwnerUser, $lk.OwnerHost, $lk.Since)), (& $Tr 'title'), 'OK', 'Warning')
			return $false
		}
		$S.Lock = $lk
		if ($lk.StaleTakeover) { & $Log 'Verwaiste Sperre einer früheren Sitzung wurde übernommen.' 'WARN' }
		return $true
	}

	$btnNext.Add_Click({
			& $Guard {
				$i = & $Cur
				switch ($i)
				{
					0
					{
						if ($UI.rbOps.Checked) { $S.Mode = 'Ops'; $S.Flow = @(0, 1, 6, 8, 9) }
						elseif ($UI.rbResume.Checked)
						{
							$st = $S.ResumeStates[$UI.cmbResume.SelectedIndex]
							if ($st.Corrupt)
							{
								[void][System.Windows.Forms.MessageBox]::Show($(if ($S.Lang -eq 'de') { "Die Zustandsdatei ist beschädigt und kann nicht geladen werden:`r`n$($st.StateFile)" } else { "The state file is damaged and cannot be loaded:`r`n$($st.StateFile)" }), (& $Tr 'title'), 'OK', 'Warning')
								return
							}
							$S.Mode = 'New'; $S.Flow = @(0..9)
							$cf = $st.Config
							$UI.txtSrcInst.Text = [string]$cf.SourceInstance
							$UI.txtTgtInst.Text = [string]$cf.TargetInstance
							$UI.txtDagName.Text = [string]$cf.DistributedAgName
							$UI.txtPort.Text = [string]$cf.EndpointPort
							$UI.txtSrcFqdn.Text = [string]$cf.SourceFqdn
							$UI.txtTgtFqdn.Text = [string]$cf.TargetFqdn
							$UI.txtAcct.Text = [string]$cf.ServiceAccount
							if ($cf.SeedingMode -eq 'Manual') { $UI.rbManual.Checked = $true } else { $UI.rbAuto.Checked = $true }
							$UI.txtBak.Text = [string]$cf.BackupPath
							$UI.txtOut.Text = [string]$cf.OutputPath
							$UI.txtListener.Text = [string]$cf.ListenerName
							$S.DbList = @($st.DbList)
							$S.ListenerA = [bool]$st.ListenerA; $S.ListenerC = [bool]$st.ListenerC
							$S.FailoverDone = [bool]$st.FailoverDone; $S.RolledBack = [bool]$st.RolledBack
							$S.Started = [bool]$st.Started
							$S.ResumePage = [int]$st.Page
							$S.ResumeAg = @($cf.SourceAgName, $cf.TargetAgName)
							& $Log "Fortsetzen: [$($cf.SourceAgName)] -> [$($cf.TargetAgName)], Seite $($st.Page)"
						}
						else { $S.Mode = 'New'; $S.Flow = @(0..9) }
					}
					1
					{
						if ($S.Mode -eq 'New')
						{
							if ($S.ResumePage -ge 0 -and $S.ResumeAg)
							{
								if ($UI.cmbSrcAg.Items.Contains($S.ResumeAg[0])) { $UI.cmbSrcAg.SelectedItem = $S.ResumeAg[0] }
								if ($UI.cmbTgtAg.Items.Contains($S.ResumeAg[1])) { $UI.cmbTgtAg.SelectedItem = $S.ResumeAg[1] }
							}
							if (-not $UI.cmbSrcAg.SelectedItem -or -not $UI.cmbTgtAg.SelectedItem)
							{
								[void][System.Windows.Forms.MessageBox]::Show((& $Tr 'c_pick'), (& $Tr 'title'), 'OK', 'Information')
								return
							}
						}
						& $CollectConfig
						if (-not (& $AcquireLock)) { return }
						& $SaveState
					}
					2 { & $CollectConfig; & $SaveState }
					3 { }
					4
					{
						$a = [System.Windows.Forms.MessageBox]::Show((& $Tr 'm_startask'), (& $Tr 'title'), 'YesNo', 'Warning')
						if ($a -ne 'Yes') { return }
						& $CollectConfig
						$S.Started = $true
						& $BuildUnits
						$S.UnitIndex = 0
						& $Go ($S.Page + 1)
						& $RunNextUnit
						return
					}
				}
				# Fortsetzen: nach dem Verbinden direkt zur gespeicherten Seite springen
				if ($i -eq 1 -and $S.ResumePage -ge 4 -and $S.Mode -eq 'New')
				{
					$target = [math]::Min($S.ResumePage, 9)
					$S.ResumePage = -1
					& $CollectConfig
					if ($target -ge 5)
					{
						& $BuildUnits
						# bereits erledigte Units markieren
						$k = 0
						foreach ($u in $S.Units) { if ($S.UnitDone.ContainsKey("$($u.Unit):$($u.Db)")) { & $SetRunRow $k 'done' ''; $k++ } else { break } }
						$S.UnitIndex = $k
					}
					$S.StatePage = $target
					$pos = [array]::IndexOf($S.Flow, $target)
					if ($target -eq 5) { & $Go $pos; if ($S.UnitIndex -lt $S.Units.Count) { $S.Started = $true; & $RunNextUnit }; return }
					& $Go $pos
					return
				}
				& $Go ($S.Page + 1)
			}
		})
	$btnBack.Add_Click({ & $Guard { & $Go ($S.Page - 1) } })
	$btnCancel.Add_Click({ & $Guard { $form.Close() } })

	$form.Add_FormClosing({
			$e = $args[1]
			try
			{
				if ($S.Busy)
				{
					$a = [System.Windows.Forms.MessageBox]::Show((& $Tr 'm_close_busy'), (& $Tr 'title'), 'YesNo', 'Warning')
					if ($a -ne 'Yes') { $e.Cancel = $true; return }
				}
				elseif ($S.Started -and -not ($S.FailoverDone -or $S.RolledBack) -and (& $Cur) -lt 9)
				{
					$a = [System.Windows.Forms.MessageBox]::Show((& $Tr 'm_close_mig'), (& $Tr 'title'), 'YesNo', 'Question')
					if ($a -ne 'Yes') { $e.Cancel = $true; return }
				}
				& $SaveState
				$tmr.Stop(); $tmrSync.Stop(); $tmrWait.Stop()
				foreach ($j in @($S.Job, $S.PJob)) { if ($j) { Stop-sqmDagBackgroundJob -Job $j } }
				if ($S.Lock) { Exit-sqmDagMigrationLock -LockFile $S.Lock.LockFile }
			}
			catch { Write-Verbose $_.Exception.Message }
		})
	$form.Add_Shown({
			& $Guard {
				& $ApplyLang
				& $ShowPage
				& $placeButtons
				if ($onShownHook)
				{
					$api = @{ Form = $form; Go = $Go; State = $S; Controls = $UI; Pages = $Pages; Log = $Log; Apply = $ApplyLang; Show = $ShowPage; Tx = $Tx; Collect = $CollectConfig; ValidateConfig = $ValidateConfig; Nav = $UpdateNav }
					& $onShownHook $api
				}
			}
		})

	[void]$form.ShowDialog()
	$form.Dispose()
}
