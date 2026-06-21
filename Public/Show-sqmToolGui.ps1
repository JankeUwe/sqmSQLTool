function Show-sqmToolGui
{
<#
.SYNOPSIS
    Launches a small graphical interface (WinForms) for all sqmSQLTool functions.
.DESCRIPTION
    Shows every exported module function grouped by category in a tree. After selecting a
    function its parameters are generated automatically as input fields. The user can fill in
    values, see a live command preview and run the command directly, copy it to the clipboard
    or display its help.

    The grouping comes from Public\category-map.ps1. Functions without an entry land under
    "Other". Read-only functions (Get-/Test-) are safe to run; state-changing functions that
    support -WhatIf automatically get a "WhatIf (simulation)" option that is enabled by default.

    The interface uses a Visual Studio "Dark" colour scheme.
.PARAMETER Filter
    Optional initial filter for the function list (wildcards allowed).
.EXAMPLE
    Show-sqmToolGui
    Opens the graphical interface with all functions.
.EXAMPLE
    Show-sqmToolGui -Filter '*AlwaysOn*'
    Opens the interface filtered directly to Always-On functions.
.NOTES
    Requires Windows PowerShell with WinForms (System.Windows.Forms). Runs synchronously in the
    current runspace: long operations block the interface while they execute.
#>
	[CmdletBinding()]
	param (
		[string]$Filter = '*'
	)

	Add-Type -AssemblyName System.Windows.Forms
	Add-Type -AssemblyName System.Drawing

	# --- Visual Studio "Dark" colour palette ---------------------------------------
	$cWindow = [System.Drawing.Color]::FromArgb(30, 30, 30)    # editors / tree / output
	$cPanel  = [System.Drawing.Color]::FromArgb(45, 45, 48)    # form / panels
	$cText   = [System.Drawing.Color]::FromArgb(220, 220, 220) # foreground
	$cDim    = [System.Drawing.Color]::FromArgb(153, 153, 153) # secondary text
	$cBtn    = [System.Drawing.Color]::FromArgb(62, 62, 66)    # buttons
	$cAccent = [System.Drawing.Color]::FromArgb(0, 122, 204)   # VS blue
	$cBorder = [System.Drawing.Color]::FromArgb(63, 63, 70)

	$styleButton = {
		param ($b)
		$b.FlatStyle = 'Flat'
		$b.BackColor = $cBtn
		$b.ForeColor = $cText
		$b.FlatAppearance.BorderColor = $cBorder
		$b.FlatAppearance.MouseOverBackColor = $cAccent
	}

	# --- Load category mapping -----------------------------------------------------
	$categoryMap = @{ }
	$mapFile = Join-Path $PSScriptRoot 'category-map.ps1'
	if (Test-Path $mapFile)
	{
		. $mapFile   # defines $categoryMap
	}

	# --- Discover functions ---------------------------------------------------------
	# Authoritative source = the manifest's FunctionsToExport (the declared public API).
	# Never enumerate Get-Command alone: if the module was imported via the bare .psm1,
	# internal helpers (and even dbatools cmdlets) would leak in under "Other".
	$module = Get-Module -Name 'sqmSQLTool'
	if (-not $module)
	{
		[System.Windows.Forms.MessageBox]::Show(
			"No sqmSQLTool functions were found. Please run 'Import-Module sqmSQLTool' first.",
			'sqmSQLTool', 'OK', 'Warning') | Out-Null
		return
	}
	$publicNames = @()
	$manifestPath = Join-Path $module.ModuleBase 'sqmSQLTool.psd1'
	if (Test-Path $manifestPath)
	{
		$publicNames = (Import-PowerShellDataFile $manifestPath).FunctionsToExport
	}
	if (-not $publicNames) { $publicNames = $module.ExportedFunctions.Keys }

	$commands = $publicNames |
	ForEach-Object { Get-Command -Name $_ -Module 'sqmSQLTool' -ErrorAction SilentlyContinue } |
	Where-Object { $_ } | Sort-Object Name
	if (-not $commands)
	{
		[System.Windows.Forms.MessageBox]::Show(
			"No sqmSQLTool functions were found. Please run 'Import-Module sqmSQLTool' first.",
			'sqmSQLTool', 'OK', 'Warning') | Out-Null
		return
	}

	# Function -> category (fallback: Other)
	$funcByCat = @{ }
	foreach ($c in $commands)
	{
		$cat = if ($categoryMap.ContainsKey($c.Name)) { $categoryMap[$c.Name] } else { 'Other' }
		if (-not $funcByCat.ContainsKey($cat)) { $funcByCat[$cat] = [System.Collections.Generic.List[string]]::new() }
		$funcByCat[$cat].Add($c.Name)
	}

	# --- Main window ---------------------------------------------------------------
	$form = New-Object System.Windows.Forms.Form
	$yearSpan = "2025-$((Get-Date).ToString('yy'))"
	$form.Text = "sqmSQLTool - Function Browser  v$($module.Version)  [$($commands.Count)]   |   powershelldba.de - Janke (c) $yearSpan"
	$form.Size = New-Object System.Drawing.Size(1150, 720)
	$form.StartPosition = 'CenterScreen'
	$form.MinimumSize = New-Object System.Drawing.Size(900, 560)
	$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
	$form.BackColor = $cPanel
	$form.ForeColor = $cText

	# One shared ToolTip instance for the whole form (no per-parameter handle leak)
	$tip = New-Object System.Windows.Forms.ToolTip

	# Split: left (tree) / right (details). 33 / 66 ratio, kept on resize.
	$split = New-Object System.Windows.Forms.SplitContainer
	$split.Dock = 'Fill'
	$split.FixedPanel = 'None'
	$split.Panel1MinSize = 220
	$split.BackColor = $cBorder
	$form.Controls.Add($split)

	# --- Left side: search box + TreeView ------------------------------------------
	$searchBox = New-Object System.Windows.Forms.TextBox
	$searchBox.Dock = 'Top'
	$searchBox.Margin = '3,3,3,3'
	$searchBox.BackColor = $cWindow
	$searchBox.ForeColor = $cText
	$searchBox.BorderStyle = 'FixedSingle'
	$lblSearch = New-Object System.Windows.Forms.Label
	$lblSearch.Text = 'Search / filter:'
	$lblSearch.Dock = 'Top'
	$lblSearch.Height = 18
	$lblSearch.ForeColor = $cDim

	$tree = New-Object System.Windows.Forms.TreeView
	$tree.Dock = 'Fill'
	$tree.HideSelection = $false
	$tree.Font = New-Object System.Drawing.Font('Segoe UI', 9)
	$tree.BackColor = $cWindow
	$tree.ForeColor = $cText
	$tree.BorderStyle = 'None'
	$tree.LineColor = $cDim

	$split.Panel1.Controls.Add($tree)
	$split.Panel1.Controls.Add($searchBox)
	$split.Panel1.Controls.Add($lblSearch)
	$split.Panel1.BackColor = $cPanel

	# (Re-)populate the tree from a filter
	$populateTree = {
		param ($flt)
		$tree.BeginUpdate()
		$tree.Nodes.Clear()
		if ([string]::IsNullOrWhiteSpace($flt)) { $flt = '*' }
		if ($flt -notmatch '[\*\?]') { $flt = "*$flt*" }
		foreach ($cat in ($funcByCat.Keys | Sort-Object))
		{
			$matched = $funcByCat[$cat] | Where-Object { $_ -like $flt }
			if (-not $matched) { continue }
			$catNode = $tree.Nodes.Add("$cat  ($($matched.Count))")
			$catNode.Tag = $null
			foreach ($fn in ($matched | Sort-Object))
			{
				$n = $catNode.Nodes.Add($fn)
				$n.Tag = $fn
			}
		}
		if ($tree.Nodes.Count -le 4) { $tree.ExpandAll() }
		$tree.EndUpdate()
	}

	# --- Right side: layout --------------------------------------------------------
	$right = New-Object System.Windows.Forms.TableLayoutPanel
	$right.Dock = 'Fill'
	$right.ColumnCount = 1
	$right.RowCount = 4
	$right.Padding = '6,6,6,6'
	$right.BackColor = $cPanel
	[void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 130)))  # header
	[void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 55)))     # parameters
	[void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 122)))   # preview + options + buttons
	[void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 45)))     # output
	$split.Panel2.Controls.Add($right)
	$split.Panel2.BackColor = $cPanel

	# Header: function name + synopsis
	$header = New-Object System.Windows.Forms.Panel
	$header.Dock = 'Fill'
	$lblFunc = New-Object System.Windows.Forms.Label
	$lblFunc.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
	$lblFunc.Dock = 'Top'
	$lblFunc.Height = 26
	$lblFunc.Text = 'Select a function on the left'
	$lblFunc.ForeColor = $cText
	$lblSyn = New-Object System.Windows.Forms.Label
	$lblSyn.Dock = 'Fill'
	$lblSyn.ForeColor = $cDim
	$lblSyn.AutoSize = $false
	$lblSyn.Padding = '0,4,0,0'
	$header.Controls.Add($lblSyn)
	$header.Controls.Add($lblFunc)
	$right.Controls.Add($header, 0, 0)

	# Parameter area (scrollable). FlowLayoutPanel mit einem festen Zeilen-Panel pro Parameter
	# -> Label und Eingabe stehen garantiert auf einer Linie (kein TableLayout-Zentrieren).
	$paramPanel = New-Object System.Windows.Forms.FlowLayoutPanel
	$paramPanel.Dock = 'Fill'
	$paramPanel.AutoScroll = $true
	$paramPanel.FlowDirection = 'TopDown'
	$paramPanel.WrapContents = $false
	$paramPanel.BackColor = $cPanel
	$grpParams = New-Object System.Windows.Forms.GroupBox
	$grpParams.Text = 'Parameters'
	$grpParams.Dock = 'Fill'
	$grpParams.ForeColor = $cText
	$grpParams.Controls.Add($paramPanel)
	$right.Controls.Add($grpParams, 0, 1)

	# Preview + buttons
	$midPanel = New-Object System.Windows.Forms.Panel
	$midPanel.Dock = 'Fill'
	$preview = New-Object System.Windows.Forms.TextBox
	$preview.Multiline = $true
	$preview.ReadOnly = $true
	$preview.Dock = 'Top'
	$preview.Height = 56
	$preview.ScrollBars = 'Vertical'
	$preview.BackColor = $cWindow
	$preview.ForeColor = [System.Drawing.Color]::FromArgb(86, 156, 214) # VS string blue
	$preview.BorderStyle = 'FixedSingle'
	$preview.Font = New-Object System.Drawing.Font('Consolas', 9)

	$btnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
	$btnPanel.Dock = 'Bottom'
	$btnPanel.Height = 34
	$btnRun = New-Object System.Windows.Forms.Button
	$btnRun.Text = 'Run command'
	$btnRun.Width = 130
	$btnRun.Enabled = $false
	$btnCopy = New-Object System.Windows.Forms.Button
	$btnCopy.Text = 'Copy to clipboard'
	$btnCopy.Width = 130
	$btnCopy.Enabled = $false
	$btnHelp = New-Object System.Windows.Forms.Button
	$btnHelp.Text = 'Help'
	$btnHelp.Width = 80
	$btnHelp.Enabled = $false
	foreach ($b in @($btnRun, $btnCopy, $btnHelp)) { & $styleButton $b }
	$btnPanel.Controls.AddRange(@($btnRun, $btnCopy, $btnHelp))

	# WhatIf on its own line (full label always visible)
	$optPanel = New-Object System.Windows.Forms.Panel
	$optPanel.Dock = 'Bottom'
	$optPanel.Height = 26
	$chkWhatIf = New-Object System.Windows.Forms.CheckBox
	$chkWhatIf.Text = 'WhatIf (simulation - shows what would happen, changes nothing)'
	$chkWhatIf.Dock = 'Fill'
	$chkWhatIf.TextAlign = 'MiddleLeft'
	$chkWhatIf.Checked = $true
	$chkWhatIf.Visible = $false
	$chkWhatIf.ForeColor = $cText
	$optPanel.Controls.Add($chkWhatIf)

	# Dock order: buttons (very bottom) -> options (above buttons) -> preview (fills top)
	$midPanel.Controls.Add($btnPanel)
	$midPanel.Controls.Add($optPanel)
	$midPanel.Controls.Add($preview)
	$right.Controls.Add($midPanel, 0, 2)

	# Output area
	$grpOut = New-Object System.Windows.Forms.GroupBox
	$grpOut.Text = 'Output'
	$grpOut.Dock = 'Fill'
	$grpOut.ForeColor = $cText
	$output = New-Object System.Windows.Forms.TextBox
	$output.Multiline = $true
	$output.ReadOnly = $true
	$output.Dock = 'Fill'
	$output.ScrollBars = 'Both'
	$output.WordWrap = $false
	$output.BackColor = $cWindow
	$output.ForeColor = $cText
	$output.BorderStyle = 'FixedSingle'
	$output.Font = New-Object System.Drawing.Font('Consolas', 9)
	$grpOut.Controls.Add($output)
	$right.Controls.Add($grpOut, 0, 3)

	# --- State of the currently selected function ----------------------------------
	# Controls: regular inputs (textbox/checkbox/combobox). Creds: PSCredential parameters.
	$script:guiState = @{ Command = $null; Controls = @{ }; Creds = @{ } }
	$script:synCache = @{ }
	$common = [System.Management.Automation.PSCmdlet]::CommonParameters +
	[System.Management.Automation.PSCmdlet]::OptionalCommonParameters

	# Build the command preview from the inputs ------------------------------------
	$buildCommand = {
		if (-not $script:guiState.Command) { return $null }
		$fn = $script:guiState.Command.Name
		$parts = [System.Collections.Generic.List[string]]::new()
		$parts.Add($fn)
		foreach ($pname in $script:guiState.Controls.Keys)
		{
			$ctrl = $script:guiState.Controls[$pname]
			if ($ctrl -is [System.Windows.Forms.CheckBox])
			{
				if ($ctrl.Checked) { $parts.Add("-$pname") }
			}
			elseif ($ctrl -is [System.Windows.Forms.ComboBox])
			{
				if ($ctrl.SelectedItem) { $parts.Add("-$pname $($ctrl.SelectedItem)") }
			}
			else
			{
				$val = $ctrl.Text
				if (-not [string]::IsNullOrWhiteSpace($val))
				{
					if ($val -match '[\s'']') { $val = "'" + ($val -replace "'", "''") + "'" }
					$parts.Add("-$pname $val")
				}
			}
		}
		foreach ($cn in $script:guiState.Creds.Keys)
		{
			$cred = $script:guiState.Creds[$cn].Cred
			if ($cred) { $parts.Add("-$cn (Get-Credential -UserName '$($cred.UserName)' -Message '...')") }
		}
		if ($chkWhatIf.Visible -and $chkWhatIf.Checked) { $parts.Add('-WhatIf') }
		return ($parts -join ' ')
	}

	$updatePreview = { $preview.Text = (& $buildCommand) }

	# Build the parameter fields for a function -------------------------------------
	$loadFunction = {
		param ($fnName)
		$cmd = Get-Command $fnName -ErrorAction SilentlyContinue
		if (-not $cmd) { return }
		$script:guiState.Command = $cmd
		$script:guiState.Controls = @{ }
		$script:guiState.Creds = @{ }

		$lblFunc.Text = $fnName
		# Parse the synopsis quickly from the source file (Get-Help is much slower), cached.
		if (-not $script:synCache.ContainsKey($fnName))
		{
			$syn = ''
			$srcFile = $cmd.ScriptBlock.File
			if ($srcFile -and (Test-Path $srcFile))
			{
				$src = Get-Content $srcFile -Raw
				if ($src -match '(?ms)\.SYNOPSIS[ \t]*\r?\n(.*?)\r?\n[ \t]*(?:\.[A-Z]|#>)')
				{
					$syn = ($Matches[1] -replace '(?m)^\s+', '').Trim()
				}
			}
			$script:synCache[$fnName] = $syn
		}
		$lblSyn.Text = $script:synCache[$fnName]

		# Show WhatIf only when the function supports ShouldProcess
		$supportsWhatIf = $cmd.Parameters.ContainsKey('WhatIf')
		$chkWhatIf.Visible = $supportsWhatIf
		$chkWhatIf.Checked = $supportsWhatIf

		$paramPanel.SuspendLayout()
		$paramPanel.Controls.Clear()
		$row = 0
		foreach ($p in $cmd.Parameters.Values)
		{
			if ($common -contains $p.Name) { continue }
			if ($p.Name -in @('WhatIf', 'Confirm')) { continue }

			$isMandatory = $false
			foreach ($a in $p.Attributes)
			{
				if ($a -is [System.Management.Automation.ParameterAttribute] -and $a.Mandatory) { $isMandatory = $true }
			}
			# ValidateSet -> allowed values for a dropdown
			$validValues = $null
			$vsAttr = $p.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | Select-Object -First 1
			if ($vsAttr) { $validValues = $vsAttr.ValidValues }

			$lbl = New-Object System.Windows.Forms.Label
			$lbl.Text = $p.Name + $(if ($isMandatory) { ' *' } else { '' })
			$lbl.AutoSize = $false
			$lbl.Location = New-Object System.Drawing.Point(3, 6)
			$lbl.Width = 185
			$lbl.Height = 20
			$lbl.TextAlign = 'MiddleLeft'
			$lbl.ForeColor = if ($isMandatory) { $cText } else { $cDim }
			if ($isMandatory) { $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold) }
			$tip.SetToolTip($lbl, "$($p.ParameterType.Name)")

			$pt = $p.ParameterType
			$isCred = $false
			if ($pt -eq [switch] -or $pt -eq [bool])
			{
				$ctrl = New-Object System.Windows.Forms.CheckBox
				$ctrl.AutoSize = $true
				$ctrl.ForeColor = $cText
				$ctrl.Add_CheckedChanged($updatePreview)
			}
			elseif ($validValues -or $pt.IsEnum)
			{
				$ctrl = New-Object System.Windows.Forms.ComboBox
				$ctrl.DropDownStyle = 'DropDownList'
				$ctrl.Width = 280
				$ctrl.BackColor = $cWindow
				$ctrl.ForeColor = $cText
				$ctrl.FlatStyle = 'Flat'
				[void]$ctrl.Items.Add('')
				$values = if ($validValues) { $validValues } else { [Enum]::GetNames($pt) }
				foreach ($ev in $values) { [void]$ctrl.Items.Add($ev) }
				$ctrl.Add_SelectedIndexChanged($updatePreview)
			}
			elseif ($pt.Name -eq 'PSCredential')
			{
				# Credential: read-only username box + Set.../Clear buttons; the PSCredential
				# object is stored in $guiState.Creds, not in Controls.
				$isCred = $true
				$ctrl = New-Object System.Windows.Forms.FlowLayoutPanel
				$ctrl.AutoSize = $false
				$ctrl.Width = 320
				$ctrl.Height = 26
				$ctrl.WrapContents = $false
				$ctrl.Margin = '0,0,0,0'
				$txtUser = New-Object System.Windows.Forms.TextBox
				$txtUser.Width = 190
				$txtUser.ReadOnly = $true
				$txtUser.BackColor = $cWindow
				$txtUser.ForeColor = $cText
				$txtUser.BorderStyle = 'FixedSingle'
				$btnSet = New-Object System.Windows.Forms.Button
				$btnSet.Text = 'Set...'
				$btnSet.Width = 60
				& $styleButton $btnSet
				$btnClr = New-Object System.Windows.Forms.Button
				$btnClr.Text = 'Clear'
				$btnClr.Width = 55
				& $styleButton $btnClr
				$pn = $p.Name
				$btnSet.Add_Click({
						$c = Get-Credential -Message "Credential for -$pn" -ErrorAction SilentlyContinue
						if ($c) { $script:guiState.Creds[$pn].Cred = $c; $txtUser.Text = $c.UserName; & $updatePreview }
					}.GetNewClosure())
				$btnClr.Add_Click({
						$script:guiState.Creds[$pn].Cred = $null; $txtUser.Text = ''; & $updatePreview
					}.GetNewClosure())
				$ctrl.Controls.AddRange(@($txtUser, $btnSet, $btnClr))
				$script:guiState.Creds[$pn] = @{ Cred = $null }
			}
			else
			{
				$ctrl = New-Object System.Windows.Forms.TextBox
				$ctrl.Width = 320
				$ctrl.BackColor = $cWindow
				$ctrl.ForeColor = $cText
				$ctrl.BorderStyle = 'FixedSingle'
				# Pre-fill instance parameters with the current machine name
				if ($p.Name -in @('SqlInstance', 'Instance')) { $ctrl.Text = $env:COMPUTERNAME }
				$ctrl.Add_TextChanged($updatePreview)
			}
			# Ein Zeilen-Panel pro Parameter: Label links, Eingabe rechts, auf einer Linie.
			$rowP = New-Object System.Windows.Forms.Panel
			$rowP.Width = 540
			$rowP.Height = 30
			$rowP.Margin = '0,0,0,2'
			$rowP.BackColor = $cPanel
			# Control vertikal mittig zur Zeile positionieren (CheckBox kleiner als Textbox)
			$ctrlHeight = if ($ctrl -is [System.Windows.Forms.CheckBox]) { 18 } else { $ctrl.Height }
			$ctrl.Location = New-Object System.Drawing.Point(195, [Math]::Max(2, [int]((30 - $ctrlHeight) / 2)))
			$rowP.Controls.Add($lbl)
			$rowP.Controls.Add($ctrl)
			$paramPanel.Controls.Add($rowP)
			if (-not $isCred) { $script:guiState.Controls[$p.Name] = $ctrl }
			$row++
		}
		if ($row -eq 0)
		{
			$none = New-Object System.Windows.Forms.Label
			$none.Text = '(No parameters)'
			$none.AutoSize = $true
			$none.ForeColor = $cDim
			$paramPanel.Controls.Add($none)
		}
		$paramPanel.ResumeLayout()

		$btnRun.Enabled = $true
		$btnCopy.Enabled = $true
		$btnHelp.Enabled = $true
		& $updatePreview

		# Output sofort aktualisieren: Funktionsname + Synopsis + Befehlsvorschau
		$sep = '-' * [Math]::Max($fnName.Length, 12)
		$output.Text = "$fnName`r`n$sep`r`n$($script:synCache[$fnName])`r`n`r`nVorschau:`r`n  $(& $buildCommand)`r`n"
	}

	# --- Events --------------------------------------------------------------------
	$tree.Add_AfterSelect({
			$node = $tree.SelectedNode
			if ($node -and $node.Tag) { & $loadFunction $node.Tag }
		})

	# Auch ein erneuter Klick auf einen bereits ausgewaehlten Funktions-Node aktualisiert sofort
	$tree.Add_NodeMouseClick({
			param ($sender, $e)
			if ($e.Node -and $e.Node.Tag) { & $loadFunction $e.Node.Tag }
		})

	$searchBox.Add_TextChanged({ & $populateTree $searchBox.Text })

	$btnCopy.Add_Click({
			$cmd = & $buildCommand
			if ($cmd) { [System.Windows.Forms.Clipboard]::SetText($cmd) }
		})

	$btnHelp.Add_Click({
			if ($script:guiState.Command)
			{
				$h = Get-Help $script:guiState.Command.Name -Full -ErrorAction SilentlyContinue | Out-String
				$output.Text = $h
			}
		})

	$btnRun.Add_Click({
			if (-not $script:guiState.Command) { return }
			# Validate mandatory fields
			$missing = @()
			foreach ($pname in $script:guiState.Controls.Keys)
			{
				$p = $script:guiState.Command.Parameters[$pname]
				$man = $false
				foreach ($a in $p.Attributes) { if ($a -is [System.Management.Automation.ParameterAttribute] -and $a.Mandatory) { $man = $true } }
				if ($man)
				{
					$ctrl = $script:guiState.Controls[$pname]
					if ($ctrl -is [System.Windows.Forms.TextBox] -and [string]::IsNullOrWhiteSpace($ctrl.Text)) { $missing += $pname }
				}
			}
			foreach ($cn in $script:guiState.Creds.Keys)
			{
				$cp = $script:guiState.Command.Parameters[$cn]
				$man = $false
				foreach ($a in $cp.Attributes) { if ($a -is [System.Management.Automation.ParameterAttribute] -and $a.Mandatory) { $man = $true } }
				if ($man -and -not $script:guiState.Creds[$cn].Cred) { $missing += $cn }
			}
			if ($missing.Count -gt 0)
			{
				[System.Windows.Forms.MessageBox]::Show("Required parameters missing:`n  - $($missing -join "`n  - ")", 'Incomplete input', 'OK', 'Warning') | Out-Null
				return
			}

			# Build parameter hashtable (splatting)
			$params = @{ }
			foreach ($pname in $script:guiState.Controls.Keys)
			{
				$ctrl = $script:guiState.Controls[$pname]
				if ($ctrl -is [System.Windows.Forms.CheckBox]) { if ($ctrl.Checked) { $params[$pname] = $true } }
				elseif ($ctrl -is [System.Windows.Forms.ComboBox]) { if ($ctrl.SelectedItem) { $params[$pname] = [string]$ctrl.SelectedItem } }
				else { if (-not [string]::IsNullOrWhiteSpace($ctrl.Text)) { $params[$pname] = $ctrl.Text } }
			}
			foreach ($cn in $script:guiState.Creds.Keys)
			{
				if ($script:guiState.Creds[$cn].Cred) { $params[$cn] = $script:guiState.Creds[$cn].Cred }
			}
			if ($chkWhatIf.Visible -and $chkWhatIf.Checked) { $params['WhatIf'] = $true }

			$fn = $script:guiState.Command.Name
			$output.Text = ">> $(& $buildCommand)`r`n`r`n"
			$form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
			$btnRun.Enabled = $false
			# Detect connection/network errors and report them clearly
			$connHint = '(?i)network-related|server was not found|login failed|certificate chain|untrusted|timeout|connect to|connection.*(fail|refused|reset)|sql server.*not (found|accessible)|named pipes|tcp provider'
			try
			{
				$records = & $fn @params 2>&1
				$errRecords = $records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
				$normal = $records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }

				$txt = ($normal | Out-String)
				if ($txt.Trim()) { $output.AppendText($txt) }

				foreach ($er in $errRecords)
				{
					$msg = "$($er.Exception.Message) $($er.Exception.InnerException.Message)"
					if ($msg -match $connHint)
					{
						$output.AppendText("`r`nSQL CONNECTION FAILED`r`nInstance '$($params['SqlInstance'])' is unreachable or login was refused.`r`nDetails: $($er.Exception.Message)`r`n")
					}
					else
					{
						$output.AppendText("`r`nERROR: $($er.Exception.Message)`r`n")
					}
				}
				if (-not $txt.Trim() -and -not $errRecords) { $output.AppendText("(No result / no output)`r`n") }
			}
			catch
			{
				$msg = "$($_.Exception.Message) $($_.Exception.InnerException.Message)"
				if ($msg -match $connHint)
				{
					$output.AppendText("SQL CONNECTION FAILED`r`nInstance '$($params['SqlInstance'])' is unreachable or login was refused.`r`nDetails: $($_.Exception.Message)`r`n")
				}
				else
				{
					$output.AppendText("ERROR ($($_.Exception.GetType().Name)): $($_.Exception.Message)`r`n")
				}
			}
			finally
			{
				$form.Cursor = [System.Windows.Forms.Cursors]::Default
				$btnRun.Enabled = $true
			}
		})

	# Keep the 33 / 66 split ratio on show and on resize
	$applySplit = {
		if ($split.Width -gt ($split.Panel1MinSize + $split.Panel2MinSize + 10))
		{
			$split.SplitterDistance = [int]($split.Width * 0.33)
		}
	}
	$split.Add_SizeChanged($applySplit)

	# Bring the window to the front after loading and set the split ratio
	$form.Add_Shown({
			& $applySplit
			$form.Activate()
			$form.BringToFront()
			$form.TopMost = $true
			$form.TopMost = $false
		})

	# --- Initial population --------------------------------------------------------
	$searchBox.Text = if ($Filter -eq '*') { '' } else { $Filter }
	& $populateTree $searchBox.Text

	[void]$form.ShowDialog()
	$tip.Dispose()
	$form.Dispose()
}
