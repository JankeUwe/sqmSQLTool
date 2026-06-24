function Show-sqmBackupExcludeForm
{
<#
.SYNOPSIS
    WinForms-Dialog zur Verwaltung der Backup-Ausschlusstabelle (master.dbo.sqm_BackupExclude).

.DESCRIPTION
    Zeigt alle Eintraege aus master.dbo.sqm_BackupExclude in einem Grid an.
    Der Anwender kann IsActive per Checkbox an- oder abwaehlen und den Reason-Text
    aendern. Verwaiste Eintraege (IsOrphaned=1) werden farblich hervorgehoben.

    Ablauf:
      1. SqlInstance eingeben (Standard: $env:COMPUTERNAME).
      2. "Sync & Laden" — fuehrt Sync-sqmBackupExcludeTable aus und laedt das Grid.
      3. IsActive-Haken setzen/entfernen, ggf. Reason anpassen.
      4. "Speichern" — schreibt nur geaenderte Zeilen per UPDATE zurueck.

.PARAMETER SqlInstance
    SQL-Instanz, die beim Oeffnen des Dialogs vorbelegt wird.

.PARAMETER SqlCredential
    Optionale Anmeldedaten (PSCredential). Ohne Angabe: Windows-Authentifizierung.

.EXAMPLE
    Show-sqmBackupExcludeForm

.EXAMPLE
    Show-sqmBackupExcludeForm -SqlInstance "SQL01\INST1"

.NOTES
    Benoetigt: dbatools, Sync-sqmBackupExcludeTable, Invoke-sqmLogging.
    Laeuft synchron im aktuellen Runspace (keine Hintergrund-Jobs).
#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$SqlInstance,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # ----- Farbpalette (identisch mit Show-sqmToolGui) --------------------------------
    $cWindow  = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $cPanel   = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $cText    = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $cDim     = [System.Drawing.Color]::FromArgb(153, 153, 153)
    $cBtn     = [System.Drawing.Color]::FromArgb(62, 62, 66)
    $cAccent  = [System.Drawing.Color]::FromArgb(0, 122, 204)
    $cBorder  = [System.Drawing.Color]::FromArgb(63, 63, 70)
    $cOrphan  = [System.Drawing.Color]::FromArgb(80, 40, 30)   # Hintergrund verwaiste Zeile
    $cSuccess = [System.Drawing.Color]::FromArgb(40, 120, 40)
    $cError   = [System.Drawing.Color]::FromArgb(140, 40, 40)

    $styleButton = {
        param ($b)
        $b.FlatStyle = 'Flat'
        $b.BackColor = $cBtn
        $b.ForeColor = $cText
        $b.FlatAppearance.BorderColor = $cBorder
        $b.FlatAppearance.MouseOverBackColor = $cAccent
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    }

    # ----- Hilfsvariable: aktuell geladene Zeilen (fuer Diff beim Speichern) ---------
    $script:originalRows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $connParams = @{ }

    # ----- Hauptfenster ---------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'sqmSQLTool – Backup-Ausschlussliste verwalten | powershelldba.de'
    $form.Size            = New-Object System.Drawing.Size(920, 640)
    $form.MinimumSize     = New-Object System.Drawing.Size(700, 480)
    $form.StartPosition   = 'CenterScreen'
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.BackColor       = $cPanel
    $form.ForeColor       = $cText
    $form.KeyPreview      = $true

    # ----- Obere Leiste (SqlInstance + Schaltflaechen) --------------------------------
    $pTop = New-Object System.Windows.Forms.Panel
    $pTop.Dock      = 'Top'
    $pTop.Height    = 44
    $pTop.BackColor = $cPanel
    $pTop.Padding   = New-Object System.Windows.Forms.Padding(6, 6, 6, 0)

    $lblInstance = New-Object System.Windows.Forms.Label
    $lblInstance.Text      = 'SQL-Instanz:'
    $lblInstance.AutoSize  = $true
    $lblInstance.Location  = New-Object System.Drawing.Point(6, 12)
    $lblInstance.ForeColor = $cDim

    $txtInstance = New-Object System.Windows.Forms.TextBox
    $txtInstance.Location  = New-Object System.Drawing.Point(90, 8)
    $txtInstance.Size      = New-Object System.Drawing.Size(240, 24)
    $txtInstance.BackColor = $cWindow
    $txtInstance.ForeColor = $cText
    $txtInstance.BorderStyle = 'FixedSingle'
    $txtInstance.Text      = if ($SqlInstance) { $SqlInstance } else { $env:COMPUTERNAME }

    $cbSysDbs = New-Object System.Windows.Forms.CheckBox
    $cbSysDbs.Text      = 'System-DBs einschliessen'
    $cbSysDbs.Location  = New-Object System.Drawing.Point(344, 9)
    $cbSysDbs.AutoSize  = $true
    $cbSysDbs.ForeColor = $cText
    $cbSysDbs.BackColor = $cPanel

    $btnLoad = New-Object System.Windows.Forms.Button
    $btnLoad.Text     = 'Sync && Laden'
    $btnLoad.Location = New-Object System.Drawing.Point(540, 6)
    $btnLoad.Size     = New-Object System.Drawing.Size(110, 28)
    & $styleButton $btnLoad

    $btnAlleAn = New-Object System.Windows.Forms.Button
    $btnAlleAn.Text     = 'Alle aktiv'
    $btnAlleAn.Location = New-Object System.Drawing.Point(660, 6)
    $btnAlleAn.Size     = New-Object System.Drawing.Size(80, 28)
    & $styleButton $btnAlleAn

    $btnAlleAus = New-Object System.Windows.Forms.Button
    $btnAlleAus.Text     = 'Alle inaktiv'
    $btnAlleAus.Location = New-Object System.Drawing.Point(748, 6)
    $btnAlleAus.Size     = New-Object System.Drawing.Size(88, 28)
    & $styleButton $btnAlleAus

    $pTop.Controls.AddRange(@($lblInstance, $txtInstance, $cbSysDbs, $btnLoad, $btnAlleAn, $btnAlleAus))

    # ----- DataGridView ---------------------------------------------------------------
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock                    = 'Fill'
    $grid.BackgroundColor         = $cWindow
    $grid.ForeColor               = $cText
    $grid.GridColor               = $cBorder
    $grid.DefaultCellStyle.BackColor    = $cWindow
    $grid.DefaultCellStyle.ForeColor    = $cText
    $grid.DefaultCellStyle.SelectionBackColor = $cAccent
    $grid.DefaultCellStyle.SelectionForeColor = $cText
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $cPanel
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $cText
    $grid.ColumnHeadersDefaultCellStyle.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $grid.EnableHeadersVisualStyles  = $false
    $grid.RowHeadersVisible          = $false
    $grid.AllowUserToAddRows         = $false
    $grid.AllowUserToDeleteRows      = $false
    $grid.AutoSizeColumnsMode        = 'Fill'
    $grid.SelectionMode              = 'FullRowSelect'
    $grid.BorderStyle                = 'None'
    $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $grid.ColumnHeadersHeight         = 28

    # Spalten definieren
    $colActive = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colActive.Name           = 'colActive'
    $colActive.HeaderText     = 'Aktiv (Backup)'
    $colActive.Width          = 100
    $colActive.AutoSizeMode   = 'None'
    $colActive.ReadOnly       = $false
    $colActive.TrueValue      = $true
    $colActive.FalseValue     = $false

    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.Name         = 'colName'
    $colName.HeaderText   = 'Datenbankname'
    $colName.ReadOnly     = $true
    $colName.FillWeight   = 35

    $colReason = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colReason.Name         = 'colReason'
    $colReason.HeaderText   = 'Reason (Begruendung)'
    $colReason.ReadOnly     = $false
    $colReason.FillWeight   = 30

    $colOrphaned = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colOrphaned.Name         = 'colOrphaned'
    $colOrphaned.HeaderText   = 'Verwaist'
    $colOrphaned.ReadOnly     = $true
    $colOrphaned.Width        = 70
    $colOrphaned.AutoSizeMode = 'None'

    $colBy = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colBy.Name         = 'colBy'
    $colBy.HeaderText   = 'Eingetragen von'
    $colBy.ReadOnly     = $true
    $colBy.FillWeight   = 20

    $colAt = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colAt.Name         = 'colAt'
    $colAt.HeaderText   = 'Eingetragen am'
    $colAt.ReadOnly     = $true
    $colAt.Width        = 140
    $colAt.AutoSizeMode = 'None'

    $grid.Columns.Add($colActive)   | Out-Null
    $grid.Columns.Add($colName)     | Out-Null
    $grid.Columns.Add($colReason)   | Out-Null
    $grid.Columns.Add($colOrphaned) | Out-Null
    $grid.Columns.Add($colBy)       | Out-Null
    $grid.Columns.Add($colAt)       | Out-Null

    # ----- Untere Leiste (Status + Speichern / Schliessen) ----------------------------
    $pBottom = New-Object System.Windows.Forms.Panel
    $pBottom.Dock      = 'Bottom'
    $pBottom.Height    = 44
    $pBottom.BackColor = $cPanel

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.AutoSize   = $false
    $lblStatus.Location   = New-Object System.Drawing.Point(6, 12)
    $lblStatus.Size       = New-Object System.Drawing.Size(810, 22)
    $lblStatus.ForeColor  = $cDim
    $lblStatus.Text       = 'Bitte eine Instanz eingeben und "Sync && Laden" klicken.'

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text     = 'Schliessen'
    $btnClose.Anchor   = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnClose.Location = New-Object System.Drawing.Point(818, 8)
    $btnClose.Size     = New-Object System.Drawing.Size(90, 28)
    & $styleButton $btnClose

    $pBottom.Controls.Add($lblStatus)
    $pBottom.Controls.Add($btnClose)

    # ----- Job-Info-Panel (zwischen Grid und Status-Leiste) ---------------------------
    $pJobInfo = New-Object System.Windows.Forms.Panel
    $pJobInfo.Dock      = 'Bottom'
    $pJobInfo.Height    = 200
    $pJobInfo.BackColor = [System.Drawing.Color]::FromArgb(37, 37, 40)

    $lblJobHeader = New-Object System.Windows.Forms.Label
    $lblJobHeader.Text      = 'Backup-Jobs (SQL Agent)'
    $lblJobHeader.Location  = New-Object System.Drawing.Point(6, 4)
    $lblJobHeader.AutoSize  = $true
    $lblJobHeader.ForeColor = $cDim
    $lblJobHeader.Font      = New-Object System.Drawing.Font('Segoe UI', 8)

    $rtfJobInfo = New-Object System.Windows.Forms.TextBox
    $rtfJobInfo.Multiline   = $true
    $rtfJobInfo.ReadOnly    = $true
    $rtfJobInfo.ScrollBars  = 'Vertical'
    $rtfJobInfo.Location    = New-Object System.Drawing.Point(6, 22)
    $rtfJobInfo.Size        = New-Object System.Drawing.Size(892, 170)
    $rtfJobInfo.Anchor      = [System.Windows.Forms.AnchorStyles]::Top -bor
                              [System.Windows.Forms.AnchorStyles]::Left -bor
                              [System.Windows.Forms.AnchorStyles]::Right
    $rtfJobInfo.BackColor   = [System.Drawing.Color]::FromArgb(37, 37, 40)
    $rtfJobInfo.ForeColor   = $cText
    $rtfJobInfo.BorderStyle = 'None'
    $rtfJobInfo.Font        = New-Object System.Drawing.Font('Consolas', 8.5)
    $rtfJobInfo.Text        = '  Noch keine Daten geladen.'

    $pJobInfo.Controls.Add($lblJobHeader)
    $pJobInfo.Controls.Add($rtfJobInfo)

    # ----- Layout zusammenbauen -------------------------------------------------------
    $form.Controls.Add($grid)
    $form.Controls.Add($pTop)
    $form.Controls.Add($pJobInfo)
    $form.Controls.Add($pBottom)

    # ----- Hilfsfunktionen -----------------------------------------------------------

    function Set-Status
    {
        param ([string]$Text, [string]$Level = 'Info')
        $lblStatus.Text = $Text
        $lblStatus.ForeColor = switch ($Level) {
            'OK'    { $cText }
            'Error' { [System.Drawing.Color]::FromArgb(255, 100, 100) }
            'Warn'  { [System.Drawing.Color]::FromArgb(220, 180, 60) }
            default { $cDim }
        }
        $form.Refresh()
    }

    function Set-RowColor
    {
        param ($row, [bool]$isOrphaned)
        if ($isOrphaned)
        {
            $row.DefaultCellStyle.BackColor = $cOrphan
            $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(200, 150, 130)
        }
        else
        {
            $row.DefaultCellStyle.BackColor = $cWindow
            $row.DefaultCellStyle.ForeColor = $cText
        }
    }

    function Load-Grid
    {
        $instance = $txtInstance.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($instance))
        {
            Set-Status 'Bitte eine SQL-Instanz eingeben.' 'Warn'
            return
        }

        Set-Status "Verbinde mit '$instance' und synchronisiere ..." 'Info'
        $grid.Rows.Clear()
        $script:originalRows.Clear()

        $script:connParams = @{ SqlInstance = $instance }
        if ($SqlCredential) { $script:connParams['SqlCredential'] = $SqlCredential }

        try
        {
            # Sync-sqmBackupExcludeTable aufrufen (legt Tabelle an / aktualisiert Waisenmarkierungen)
            $syncParams = @{ SqlInstance = $instance }
            if ($SqlCredential)            { $syncParams['SqlCredential']       = $SqlCredential }
            if ($cbSysDbs.Checked)         { $syncParams['IncludeSystemDatabases'] = $true }

            $null = Sync-sqmBackupExcludeTable @syncParams -ErrorAction Stop

            # Eintraege laden
            $rows = Invoke-DbaQuery @script:connParams -Database master `
                -Query "SELECT DatabaseName, Reason, IsActive, IsOrphaned, ExcludedBy, ExcludedAt FROM master.dbo.sqm_BackupExclude ORDER BY IsOrphaned, DatabaseName" `
                -ErrorAction Stop

            if (-not $rows)
            {
                Set-Status "Tabelle ist leer — keine Eintraege gefunden." 'Warn'
                return
            }

            $systemDbs = @('master', 'model', 'msdb', 'tempdb')

            foreach ($r in $rows)
            {
                $isOrphaned = [bool]$r.IsOrphaned
                $isActive   = [bool]$r.IsActive
                $dbName     = $r.DatabaseName
                $reason     = if ($r.Reason) { $r.Reason } else { '' }
                $by         = $r.ExcludedBy
                $at         = if ($r.ExcludedAt) { ([datetime]$r.ExcludedAt).ToString('dd.MM.yyyy HH:mm') } else { '' }
                $isSysDb    = $dbName -in $systemDbs

                $rowIdx = $grid.Rows.Add($isActive, $dbName, $reason, $(if ($isOrphaned) { 'Ja' } else { '' }), $by, $at)
                $gridRow = $grid.Rows[$rowIdx]

                if ($isSysDb)
                {
                    # System-DBs: Checkbox und Reason sperren, visuell kennzeichnen
                    $gridRow.Cells['colActive'].ReadOnly = $true
                    $gridRow.Cells['colReason'].ReadOnly = $true
                    $gridRow.DefaultCellStyle.ForeColor  = $cDim
                    $gridRow.DefaultCellStyle.BackColor  = [System.Drawing.Color]::FromArgb(35, 35, 38)
                    $gridRow.Cells['colName'].ToolTipText = 'System-Datenbank — kann nicht ausgeschlossen werden'
                }
                else
                {
                    Set-RowColor $gridRow $isOrphaned
                }

                # Original fuer spaeteres Diff merken
                $script:originalRows.Add([PSCustomObject]@{
                    DatabaseName = $dbName
                    IsActive     = $isActive
                    Reason       = $reason
                    IsOrphaned   = $isOrphaned
                    IsSystemDb   = $isSysDb
                })
            }

            Set-Status "$($rows.Count) Eintrag/Eintraege geladen. Haken setzen = Backup aktiv." 'OK'
        }
        catch
        {
            Set-Status "Fehler: $($_.Exception.Message)" 'Error'
        }

        # Load-JobInfo ausserhalb des try-Blocks — Fehler dort sollen den Save-Button nicht blockieren
        try { Load-JobInfo } catch { $rtfJobInfo.Text = "  Job-Info nicht verfuegbar: $($_.Exception.Message)" }
    }

    function Save-Row
    {
        param ([int]$RowIndex)

        if (-not $script:connParams.Count) { Set-Status 'Keine Verbindung — bitte zuerst laden.' 'Warn'; return }
        if ($RowIndex -lt 0 -or $RowIndex -ge $grid.Rows.Count) { return }

        $row    = $grid.Rows[$RowIndex]
        $dbName = $row.Cells['colName'].Value

        $orig = $script:originalRows | Where-Object { $_.DatabaseName -eq $dbName } | Select-Object -First 1
        if (-not $orig) { return }

        # System-DBs und Waisen nie schreiben
        if ($orig.IsSystemDb -or ($row.Cells['colOrphaned'].Value -eq 'Ja')) { return }

        $cellVal   = $row.Cells['colActive'].Value
        $newActive = if ($null -eq $cellVal) { $false } else { [bool]$cellVal }
        $newReason = if ($row.Cells['colReason'].Value) { $row.Cells['colReason'].Value.ToString().Trim() } else { '' }

        $origActive = [bool]$orig.IsActive
        $origReason = if ($null -eq $orig.Reason) { '' } else { "$($orig.Reason)" }

        $activeChanged = ($newActive -ne $origActive)
        $reasonChanged = ($newReason -ne $origReason)
        if (-not $activeChanged -and -not $reasonChanged) { return }

        $setParts = [System.Collections.Generic.List[string]]::new()
        if ($activeChanged) { $setParts.Add("IsActive = $(if ($newActive) { 1 } else { 0 })") }
        if ($reasonChanged) { $setParts.Add("Reason = $(if ([string]::IsNullOrWhiteSpace($newReason)) { 'NULL' } else { "N'$($newReason.Replace("'","''"))'" })") }

        $sql = "UPDATE master.dbo.sqm_BackupExclude SET $($setParts -join ', ') WHERE DatabaseName = N'$($dbName.Replace("'","''"))'"

        # Lokale Kopie — @script:connParams als Splatting in nested functions nicht zuverlaessig
        $cp = $script:connParams
        try
        {
            Invoke-DbaQuery @cp -Database master -Query $sql -ErrorAction Stop
            $orig.IsActive = $newActive
            $orig.Reason   = $newReason
            Set-Status "'$dbName' gespeichert." 'OK'
        }
        catch
        {
            Set-Status "Fehler '$dbName': $($_.Exception.Message)" 'Error'
        }
    }

    function Load-JobInfo
    {
        $rtfJobInfo.Text = '  Lese Job-Konfiguration ...'
        $form.Refresh()

        $cfg = @{}
        try { $cfg = Get-sqmConfig } catch { }

        $jobNames = [ordered]@{
            FULL = if ($cfg['OlaJobNameFull']) { $cfg['OlaJobNameFull'] } else { 'OlaHH-UserDatabases-FULL' }
            LOG  = if ($cfg['OlaJobNameLog'])  { $cfg['OlaJobNameLog']  } else { 'OlaHH-UserDatabases-LOG'  }
            DIFF = if ($cfg['OlaJobNameDiff']) { $cfg['OlaJobNameDiff'] } else { 'OlaHH-UserDatabases-DIFF' }
        }

        # Liest einen benannten Ola-Parameter aus dem Step-Command (static + dynamic T-SQL)
        $parseParam = {
            param ([string]$cmd, [string]$p)
            if ($cmd -match "(?i)@$p\s*=\s*(?:N?'{1,2})([^']+)") { $Matches[1] } else { '—' }
        }

        $lines = [System.Collections.Generic.List[string]]::new()

        foreach ($type in $jobNames.Keys)
        {
            $jobName = $jobNames[$type].Trim()
            $job     = Get-DbaAgentJob @script:connParams -Job $jobName -ErrorAction SilentlyContinue

            # Fallback: contains-Suche falls exakter Name nicht trifft (z.B. Spaces im Jobnamen)
            if (-not $job)
            {
                $job = Get-DbaAgentJob @script:connParams -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name.Trim() -like "*$jobName*" } |
                    Select-Object -First 1
                if ($job) { $jobName = $job.Name }
            }

            if (-not $job)
            {
                $lines.Add("  [$type]  $jobName  →  nicht gefunden")
                continue
            }

            if ($job.IsEnabled -eq $false)
            {
                continue
            }

            # Schedule
            $sched = $job.JobSchedules | Select-Object -First 1
            if ($sched)
            {
                $t      = $sched.ActiveStartTimeOfDay
                $time   = '{0:D2}:{1:D2}' -f $t.Hours, $t.Minutes
                $mask   = [int]$sched.FrequencyInterval
                $days   = @()
                if ($mask -band 2)  { $days += 'Mo' }
                if ($mask -band 4)  { $days += 'Di' }
                if ($mask -band 8)  { $days += 'Mi' }
                if ($mask -band 16) { $days += 'Do' }
                if ($mask -band 32) { $days += 'Fr' }
                if ($mask -band 64) { $days += 'Sa' }
                if ($mask -band 1)  { $days += 'So' }
                $dayStr   = if ($days.Count -eq 7) { 'taeglich' } elseif ($days.Count -eq 0) { '?' } else { $days -join '/' }
                $schedStr = "$dayStr  $time"
            }
            else { $schedStr = 'kein Schedule' }

            # Step-Command
            $cmd  = ''
            $step = $job.JobSteps | Where-Object { $_.ID -eq 1 }
            if ($step) { $cmd = $step.Command }

            $db         = & $parseParam $cmd 'Databases'
            $dir        = & $parseParam $cmd 'Directory'
            $cleanup    = if ($cmd -match '(?i)@CleanupTime\s*=\s*(\d+)') { $Matches[1] } else { '—' }
            $compress   = & $parseParam $cmd 'Compress'
            $verify     = & $parseParam $cmd 'Verify'
            $checksum   = & $parseParam $cmd 'CheckSum'
            $hasExclude = $cmd -match 'sqm_BackupExclude'

            $lines.Add("  [$type]  $jobName  |  Schedule: $schedStr")
            $lines.Add("         @Databases=$db   @Directory=$dir   @CleanupTime=${cleanup}h")
            $lines.Add("         @Compress=$compress  @Verify=$verify  @CheckSum=$checksum  ExcludeTable: $(if ($hasExclude) { 'Ja (dynamisch)' } else { 'Nein' })")
            $lines.Add('')
        }

        $rtfJobInfo.Text = ($lines -join "`r`n").TrimEnd()
    }

    # ----- Event-Handler --------------------------------------------------------------

    # Checkbox-Klick sofort committen — sonst ist der neue Wert beim Speichern noch nicht sichtbar
    $grid.Add_CurrentCellDirtyStateChanged({
        if ($grid.IsCurrentCellDirty) {
            $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })

    $btnLoad.Add_Click({ Load-Grid })

    $btnClose.Add_Click({ $form.Close() })

    # Reason-Zelle: nach Verlassen der Zelle speichern
    $grid.Add_CellEndEdit({
        param ($s, $e)
        if ($e.ColumnIndex -eq $grid.Columns['colReason'].Index -and $e.RowIndex -ge 0)
        {
            try { Save-Row $e.RowIndex }
            catch
            {
                [System.Windows.Forms.MessageBox]::Show(
                    "Fehler beim Speichern:`n$($_.Exception.Message)",
                    'Speichern – Fehler', 'OK', 'Error') | Out-Null
            }
        }
    })

    $btnAlleAn.Add_Click({
        for ($i = 0; $i -lt $grid.Rows.Count; $i++)
        {
            $grid.Rows[$i].Cells['colActive'].Value = $true
        }
    })

    $btnAlleAus.Add_Click({
        for ($i = 0; $i -lt $grid.Rows.Count; $i++)
        {
            $grid.Rows[$i].Cells['colActive'].Value = $false
        }
    })

    # Enter in SqlInstance-Box loest Laden aus
    $txtInstance.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) { Load-Grid }
    })

    # Escape schliesst den Dialog
    $form.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() }
    })

    # Checkbox-Aenderung: visuelles Feedback + sofort speichern
    $grid.Add_CellValueChanged({
        param ($s, $e)
        if ($e.ColumnIndex -eq $grid.Columns['colActive'].Index -and $e.RowIndex -ge 0)
        {
            $row      = $grid.Rows[$e.RowIndex]
            $isOrphan = ($row.Cells['colOrphaned'].Value -eq 'Ja')
            if (-not $isOrphan)
            {
                $isNowActive = [bool]$row.Cells['colActive'].Value
                $row.DefaultCellStyle.ForeColor = if ($isNowActive) { $cText } else { $cDim }
            }
            try { Save-Row $e.RowIndex }
            catch
            {
                [System.Windows.Forms.MessageBox]::Show(
                    "Fehler beim Speichern:`n$($_.Exception.Message)",
                    'Speichern – Fehler', 'OK', 'Error') | Out-Null
            }
        }
    })

    # ----- Dialog anzeigen ------------------------------------------------------------
    [void]$form.ShowDialog()
}
