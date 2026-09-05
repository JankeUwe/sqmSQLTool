<#
.SYNOPSIS
    Live-Monitor fuer Get-sqmWhoIsActive: zeigt Sessions in einem sich automatisch
    aktualisierenden Grid statt nur als Konsolen-/CSV-/HTML-Ausgabe.

.DESCRIPTION
    WinForms-Dialog um Get-sqmWhoIsActiveSnapshot herum: "Start" beginnt einen neuen
    Lauf, der per Timer im eingestellten Intervall einen Snapshot holt und das Grid
    mit dem jeweils neuesten Snapshot ueberschreibt (kein anwachsendes Grid ueber
    Stunden - immer nur der aktuelle Zustand). "Stop" (oder Fensterschliessen waehrend
    ein Lauf aktiv ist) beendet den Timer und schreibt genau wie Get-sqmWhoIsActive
    eine CSV mit allen Iterationen des Laufs plus einen HTML-Bericht mit NUR dem
    letzten Snapshot.

    Die Abfrage- und Report-Logik ist identisch zu Get-sqmWhoIsActive (gemeinsame
    private Helfer Get-sqmWhoIsActiveSnapshot / Export-sqmWhoIsActiveReport) - dieser
    Dialog ist nur eine alternative, live-aktualisierende Ansicht derselben Daten.

.PARAMETER SqlInstance
    SQL Server Instanz, mit der das Feld beim Oeffnen vorbelegt wird (default:
    aktueller Computername).

.PARAMETER SqlCredential
    Optionale Anmeldedaten (PSCredential). Ohne Angabe: Windows-Authentifizierung.

.PARAMETER RepeatIntervalSeconds
    Vorbelegung fuer das Intervall-Feld. Default: 5.

.PARAMETER OutputPath
    Verzeichnis fuer CSV/HTML nach "Stop". Default: <OutputPath config>\WhoIsActive
    (identisch zu Get-sqmWhoIsActive).

.EXAMPLE
    Show-sqmWhoIsActiveMonitor -SqlInstance "SQL01"

.NOTES
    Benoetigt: dbatools, Get-sqmWhoIsActiveSnapshot, Export-sqmWhoIsActiveReport.
    Laeuft synchron im aktuellen Runspace (keine Hintergrund-Jobs) - konsistent mit
    Show-sqmBackupExcludeForm: jeder Timer-Tick fuehrt die DMV-Abfrage auf dem
    UI-Thread aus, das Fenster ist waehrenddessen kurz blockiert. Da es sich um
    leichte DMV-Abfragen handelt, ist das in der Praxis nicht spuerbar.
#>
function Show-sqmWhoIsActiveMonitor
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 3600)]
		[int]$RepeatIntervalSeconds = 5,
		[Parameter(Mandatory = $false)]
		[string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'WhoIsActive')
	)

	Add-Type -AssemblyName System.Windows.Forms
	Add-Type -AssemblyName System.Drawing

	# ----- Farbpalette (identisch mit Show-sqmToolGui / Show-sqmBackupExcludeForm) ----
	$cWindow = [System.Drawing.Color]::FromArgb(30, 30, 30)
	$cPanel  = [System.Drawing.Color]::FromArgb(45, 45, 48)
	$cText   = [System.Drawing.Color]::FromArgb(220, 220, 220)
	$cDim    = [System.Drawing.Color]::FromArgb(153, 153, 153)
	$cBtn    = [System.Drawing.Color]::FromArgb(62, 62, 66)
	$cAccent = [System.Drawing.Color]::FromArgb(0, 122, 204)
	$cBorder = [System.Drawing.Color]::FromArgb(63, 63, 70)
	$cWarn   = [System.Drawing.Color]::FromArgb(220, 180, 60)
	$cCrit   = [System.Drawing.Color]::FromArgb(140, 40, 40)
	$cCritFg = [System.Drawing.Color]::FromArgb(240, 220, 220)

	$styleButton = {
		param ($b)
		$b.FlatStyle = 'Flat'
		$b.BackColor = $cBtn
		$b.ForeColor = $cText
		$b.FlatAppearance.BorderColor = $cBorder
		$b.FlatAppearance.MouseOverBackColor = $cAccent
		$b.Cursor = [System.Windows.Forms.Cursors]::Hand
	}

	# ----- Laufstatus (ueberlebt einzelne Event-Handler-Aufrufe) ----------------------
	$script:wiaRunning		 = $false
	$script:wiaIteration	 = 0
	$script:wiaLoopStart	 = Get-Date
	$script:wiaAllSnapshots  = [System.Collections.Generic.List[PSCustomObject]]::new()
	$script:wiaLastSnapshot  = @()

	# ----- Hauptfenster -----------------------------------------------------------------
	$form = New-Object System.Windows.Forms.Form
	$form.Text			  = 'sqmSQLTool - Who Is Active (Live) | powershelldba.de'
	$form.Size			  = New-Object System.Drawing.Size(1180, 640)
	$form.MinimumSize	  = New-Object System.Drawing.Size(820, 420)
	$form.StartPosition   = 'CenterScreen'
	$form.Font			  = New-Object System.Drawing.Font('Segoe UI', 9)
	$form.BackColor	      = $cPanel
	$form.ForeColor	      = $cText
	$form.KeyPreview	  = $true

	# ----- Obere Leiste (Instanz + Optionen + Start/Stop) -----------------------------
	$pTop = New-Object System.Windows.Forms.Panel
	$pTop.Dock	    = 'Top'
	$pTop.Height    = 44
	$pTop.BackColor = $cPanel
	$pTop.Padding   = New-Object System.Windows.Forms.Padding(6, 6, 6, 0)

	$lblInstance = New-Object System.Windows.Forms.Label
	$lblInstance.Text	   = 'SQL-Instanz:'
	$lblInstance.AutoSize  = $true
	$lblInstance.Location  = New-Object System.Drawing.Point(6, 12)
	$lblInstance.ForeColor = $cDim

	$txtInstance = New-Object System.Windows.Forms.TextBox
	$txtInstance.Location    = New-Object System.Drawing.Point(90, 8)
	$txtInstance.Size	     = New-Object System.Drawing.Size(180, 24)
	$txtInstance.BackColor   = $cWindow
	$txtInstance.ForeColor   = $cText
	$txtInstance.BorderStyle = 'FixedSingle'
	$txtInstance.Text	     = if ($SqlInstance) { $SqlInstance } else { $env:COMPUTERNAME }

	$lblInterval = New-Object System.Windows.Forms.Label
	$lblInterval.Text	   = 'Intervall (Sek.):'
	$lblInterval.AutoSize  = $true
	$lblInterval.Location  = New-Object System.Drawing.Point(284, 12)
	$lblInterval.ForeColor = $cDim

	$nudInterval = New-Object System.Windows.Forms.NumericUpDown
	$nudInterval.Location  = New-Object System.Drawing.Point(390, 8)
	$nudInterval.Size	   = New-Object System.Drawing.Size(60, 24)
	$nudInterval.Minimum   = 1
	$nudInterval.Maximum   = 3600
	$nudInterval.Value	   = $RepeatIntervalSeconds
	$nudInterval.BackColor = $cWindow
	$nudInterval.ForeColor = $cText

	$lblSleeping = New-Object System.Windows.Forms.Label
	$lblSleeping.Text	   = 'Sessions:'
	$lblSleeping.AutoSize  = $true
	$lblSleeping.Location  = New-Object System.Drawing.Point(462, 12)
	$lblSleeping.ForeColor = $cDim

	$cboSleeping = New-Object System.Windows.Forms.ComboBox
	$cboSleeping.Location	  = New-Object System.Drawing.Point(524, 8)
	$cboSleeping.Size		  = New-Object System.Drawing.Size(230, 24)
	$cboSleeping.DropDownStyle = 'DropDownList'
	$cboSleeping.BackColor	  = $cWindow
	$cboSleeping.ForeColor	  = $cText
	[void]$cboSleeping.Items.Add('0 - nur aktive Requests')
	[void]$cboSleeping.Items.Add('1 - aktiv + offene Transaktionen')
	[void]$cboSleeping.Items.Add('2 - alle Sessions')
	$cboSleeping.SelectedIndex = 1

	$cbAutoOpen = New-Object System.Windows.Forms.CheckBox
	$cbAutoOpen.Text	  = 'Bericht nach Stop oeffnen'
	$cbAutoOpen.Location  = New-Object System.Drawing.Point(766, 10)
	$cbAutoOpen.AutoSize  = $true
	$cbAutoOpen.ForeColor = $cText
	$cbAutoOpen.BackColor = $cPanel
	$cbAutoOpen.Checked   = $true

	$btnStartStop = New-Object System.Windows.Forms.Button
	$btnStartStop.Text	   = 'Start'
	$btnStartStop.Location = New-Object System.Drawing.Point(990, 6)
	$btnStartStop.Size	   = New-Object System.Drawing.Size(90, 28)
	& $styleButton $btnStartStop

	$pTop.Controls.AddRange(@($lblInstance, $txtInstance, $lblInterval, $nudInterval, $lblSleeping, $cboSleeping, $cbAutoOpen, $btnStartStop))

	# ----- DataGridView (aktueller Snapshot, wird bei jedem Tick neu befuellt) --------
	$grid = New-Object System.Windows.Forms.DataGridView
	$grid.Dock				 = 'Fill'
	$grid.BackgroundColor	 = $cWindow
	$grid.ForeColor		     = $cText
	$grid.GridColor		     = $cBorder
	$grid.DefaultCellStyle.BackColor = $cWindow
	$grid.DefaultCellStyle.ForeColor = $cText
	$grid.DefaultCellStyle.SelectionBackColor = $cAccent
	$grid.DefaultCellStyle.SelectionForeColor = $cText
	$grid.ColumnHeadersDefaultCellStyle.BackColor = $cPanel
	$grid.ColumnHeadersDefaultCellStyle.ForeColor = $cText
	$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
	$grid.EnableHeadersVisualStyles   = $false
	$grid.RowHeadersVisible		      = $false
	$grid.ReadOnly					  = $true
	$grid.AllowUserToAddRows		  = $false
	$grid.AllowUserToDeleteRows	      = $false
	$grid.AllowUserToResizeRows	      = $false
	$grid.AutoSizeColumnsMode		  = 'None'
	$grid.SelectionMode			  = 'FullRowSelect'
	$grid.BorderStyle				  = 'None'
	$grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
	$grid.ColumnHeadersHeight		  = 28
	$grid.ShowCellToolTips		      = $true

	foreach ($c in @(
			@{ N = 'colSpid';    H = 'SPID';       W = 55 }
			@{ N = 'colElapsed'; H = 'Elapsed';     W = 90 }
			@{ N = 'colStatus';  H = 'Status';      W = 90 }
			@{ N = 'colBlkBy';   H = 'Blocked by';  W = 80 }
			@{ N = 'colWait';    H = 'Wait Info';   W = 200 }
			@{ N = 'colDb';      H = 'Datenbank';   W = 120 }
			@{ N = 'colLogin';   H = 'Login';       W = 130 }
			@{ N = 'colHost';    H = 'Host';        W = 100 }
			@{ N = 'colCpu';     H = 'CPU ms';      W = 80 }
			@{ N = 'colReads';   H = 'Reads';       W = 80 }
			@{ N = 'colTempdb';  H = 'Tempdb MB';   W = 90 }
			@{ N = 'colSql';     H = 'SQL Text';    W = 260 }
		))
	{
		$col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
		$col.Name = $c.N; $col.HeaderText = $c.H; $col.Width = $c.W
		if ($c.N -eq 'colSql') { $col.AutoSizeMode = 'Fill' } else { $col.AutoSizeMode = 'None' }
		$grid.Columns.Add($col) | Out-Null
	}

	# ----- Untere Leiste (Status + Schliessen) ----------------------------------------
	$pBottom = New-Object System.Windows.Forms.Panel
	$pBottom.Dock	   = 'Bottom'
	$pBottom.Height    = 44
	$pBottom.BackColor = $cPanel

	$lblStatus = New-Object System.Windows.Forms.Label
	$lblStatus.AutoSize  = $false
	$lblStatus.Location  = New-Object System.Drawing.Point(6, 12)
	$lblStatus.Size	     = New-Object System.Drawing.Size(980, 22)
	$lblStatus.ForeColor = $cDim
	$lblStatus.Text	     = 'Bitte Instanz eingeben und "Start" klicken.'

	$btnClose = New-Object System.Windows.Forms.Button
	$btnClose.Text	   = 'Schliessen'
	$btnClose.Anchor    = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
	$btnClose.Location = New-Object System.Drawing.Point(1078, 8)
	$btnClose.Size	   = New-Object System.Drawing.Size(90, 28)
	& $styleButton $btnClose

	$pBottom.Controls.Add($lblStatus)
	$pBottom.Controls.Add($btnClose)

	$form.Controls.Add($grid)
	$form.Controls.Add($pTop)
	$form.Controls.Add($pBottom)

	# ----- Timer (ein Tick = ein neuer Snapshot = ein "Run") --------------------------
	$timer = New-Object System.Windows.Forms.Timer
	$timer.Interval = [int]$nudInterval.Value * 1000

	# ----- Hilfsfunktionen -------------------------------------------------------------

	function Set-Status
	{
		param ([string]$Text, [string]$Level = 'Info')
		$lblStatus.Text = $Text
		$lblStatus.ForeColor = switch ($Level)
		{
			'OK'	{ $cText }
			'Error' { [System.Drawing.Color]::FromArgb(255, 100, 100) }
			'Warn'  { $cWarn }
			default { $cDim }
		}
	}

	function Update-Grid
	{
		param ($Rows)
		$grid.SuspendLayout()
		$grid.Rows.Clear()
		foreach ($r in $Rows)
		{
			$elapsedTxt = Format-sqmTimeSpan -Seconds ([math]::Max(0, [int]$r.ElapsedSeconds))
			$sqlShort = if ($r.SqlText -and $r.SqlText.Length -gt 90) { $r.SqlText.Substring(0, 90) + '...' } else { $r.SqlText }
			$blkTxt = if ($r.BlockingSessionId -gt 0) { $r.BlockingSessionId } else { '' }

			$rowIdx = $grid.Rows.Add($r.SessionId, $elapsedTxt, $r.Status, $blkTxt, $r.WaitInfo,
				$r.DatabaseName, $r.LoginName, $r.HostName, $r.CpuTimeMs, $r.Reads, $r.TempdbAllocMB, $sqlShort)
			$gridRow = $grid.Rows[$rowIdx]
			if ($r.SqlFullBatch) { $gridRow.Cells['colSql'].ToolTipText = $r.SqlFullBatch }

			if ($r.BlockingSessionId -gt 0)
			{
				$gridRow.DefaultCellStyle.BackColor = $cCrit
				$gridRow.DefaultCellStyle.ForeColor = $cCritFg
			}
			elseif ($r.ElapsedSeconds -ge 30)
			{
				$gridRow.DefaultCellStyle.ForeColor = $cWarn
			}
		}
		$grid.ResumeLayout()
	}

	function Set-ControlsEnabled
	{
		param ([bool]$Enabled)
		$txtInstance.Enabled = $Enabled
		$nudInterval.Enabled = $Enabled
		$cboSleeping.Enabled = $Enabled
	}

	function Invoke-Snapshot
	{
		$script:wiaIteration++
		$captureTime = Get-Date
		try
		{
			$rows = @(Get-sqmWhoIsActiveSnapshot -SqlInstance $txtInstance.Text.Trim() -SqlCredential $SqlCredential `
					-ShowSleepingSpids $cboSleeping.SelectedIndex -Iteration $script:wiaIteration -CaptureTime $captureTime)

			foreach ($r in $rows) { $script:wiaAllSnapshots.Add($r) }
			$script:wiaLastSnapshot = $rows

			Update-Grid $rows
			Set-Status "Iteration $($script:wiaIteration) - $($captureTime.ToString('HH:mm:ss')) - $($rows.Count) Session(s)" 'OK'
		}
		catch
		{
			Set-Status "Fehler bei Iteration $($script:wiaIteration): $($_.Exception.Message)" 'Error'
		}
	}

	function Start-Monitor
	{
		$instance = $txtInstance.Text.Trim()
		if ([string]::IsNullOrWhiteSpace($instance))
		{
			Set-Status 'Bitte eine SQL-Instanz eingeben.' 'Warn'
			return
		}

		# Neuer Lauf: bisherige Snapshots verwerfen, sonst landen Zeilen mehrerer Laeufe/Instanzen in einer CSV
		$script:wiaAllSnapshots = [System.Collections.Generic.List[PSCustomObject]]::new()
		$script:wiaLastSnapshot = @()
		$script:wiaIteration = 0
		$script:wiaLoopStart = Get-Date
		$grid.Rows.Clear()

		$timer.Interval = [int]$nudInterval.Value * 1000
		$script:wiaRunning = $true
		Set-ControlsEnabled $false
		$btnStartStop.Text = 'Stop'

		Invoke-Snapshot
		$timer.Start()
	}

	function Stop-Monitor
	{
		$timer.Stop()
		$script:wiaRunning = $false
		Set-ControlsEnabled $true
		$btnStartStop.Text = 'Start'

		if ($script:wiaAllSnapshots.Count -eq 0)
		{
			Set-Status 'Gestoppt - keine Snapshots erfasst, kein Bericht geschrieben.' 'Warn'
			return
		}

		try
		{
			$report = Export-sqmWhoIsActiveReport -AllSnapshots $script:wiaAllSnapshots -LastSnapshotRows $script:wiaLastSnapshot `
				-SqlInstance $txtInstance.Text.Trim() -OutputPath $OutputPath -IterationCount $script:wiaIteration `
				-LoopStart $script:wiaLoopStart -NoOpen:(-not $cbAutoOpen.Checked)
			Set-Status "Gestoppt - $($script:wiaIteration) Snapshot(s). Bericht: $($report.HtmlFile)" 'OK'
		}
		catch
		{
			Set-Status "Gestoppt - Fehler beim Schreiben des Berichts: $($_.Exception.Message)" 'Error'
		}
	}

	# ----- Event-Handler --------------------------------------------------------------

	$timer.Add_Tick({ Invoke-Snapshot })

	$btnStartStop.Add_Click({
			if ($script:wiaRunning) { Stop-Monitor } else { Start-Monitor }
		})

	$btnClose.Add_Click({ $form.Close() })

	$form.Add_KeyDown({
			if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() }
		})

	$form.Add_FormClosing({
			if ($script:wiaRunning) { Stop-Monitor }
		})

	# ----- Dialog anzeigen ------------------------------------------------------------
	[void]$form.ShowDialog()
}
