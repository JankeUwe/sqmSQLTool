<#
.SYNOPSIS
    Grants a group or account NTFS rights on whole data volumes or folders, including all
    subfolders whose inheritance is broken.

.DESCRIPTION
    Sets an inheritable Allow ACE ((OI)(CI)) for the chosen principals on the root of each target.
    Windows passes it on to everything below that still inherits. Folders whose inheritance is
    switched off (protected DACL) do not receive it that way; the function finds them and sets the
    same ACE on each of them explicitly, which in turn reaches everything below them.

    Compared with "icacls <root> /grant ... /T" this
      - leaves no duplicate ACE (explicit + inherited) on every folder,
      - does not re-propagate the whole subtree once per folder (hours on large volumes),
      - skips "System Volume Information" and "$RECYCLE.BIN" (access denied even for
        Administrators, which made every run end with an error code),
      - does not follow junctions, symbolic links or mounted volumes (reparse points), so it never
        changes a volume that was not asked for,
      - checks before each change whether the right is already there and changes nothing then,
        so a repeated run is cheap,
      - reads the ACL back after each change and only reports Granted when the right is really set.

    Principals: -Principal for the well-known groups (by SID, independent of the OS language)
    and/or -Account for any other local or domain group/account or SID.

    The system drive is never touched, not even a folder on it. Drives in -ExcludeDrive (default
    C and S) are skipped, also for -Path. Only NTFS and ReFS are processed.

    SECURITY: on SQL Server data, log and backup volumes "Authenticated Users" with read access can
    read every .bak file, i.e. a full copy of the data, for anyone who can log on or reach the
    folder via a share. Prefer a dedicated group (-Account) and the narrowest -Path possible.

.PARAMETER Principal
    Well-known group(s): AuthenticatedUsers (S-1-5-11), Administrators (S-1-5-32-544).
    At least one of -Principal or -Account is required.

.PARAMETER Account
    Further groups/accounts, e.g. 'DOMAIN\SQL-Readers', 'DEV03\Monitoring', or a SID ('S-1-5-...').

.PARAMETER Rights
    ReadAndExecute (default), Read, Modify or FullControl. Applies to all principals of the call;
    call the function once per rights level.

.PARAMETER DriveLetter
    Drives to process. Default: F, G, H, I. Ignored when -Path is given.

.PARAMETER Path
    Folders or drive roots to process instead of -DriveLetter (e.g. 'H:\MSSQL\Backup').

.PARAMETER ExcludeDrive
    Drives that are never touched. Default: C, S. The system drive is always excluded.

.PARAMETER IncludeFiles
    Also check every file for broken inheritance and grant on those. Files rarely have a
    protected DACL; this reads the ACL of every file and takes correspondingly long.

.PARAMETER EnableException
    Throw exceptions immediately instead of reporting them as Failed.

.EXAMPLE
    Grant-sqmVolumeAccess -Principal AuthenticatedUsers -WhatIf

    Shows for F:, G:, H:, I: what would be granted, including the folders with broken inheritance.

.EXAMPLE
    Grant-sqmVolumeAccess -Principal Administrators -Rights FullControl -DriveLetter F, G, H, I

    Gives the local Administrators full control on the four data volumes.

.EXAMPLE
    Grant-sqmVolumeAccess -Account 'DOMAIN\SQL-Monitoring' -Path 'F:\MSSQL\Log', 'H:\MSSQL\Log'

    Read & Execute for one domain group, only on the two log folders.

.EXAMPLE
    Grant-sqmVolumeAccess -Principal AuthenticatedUsers, Administrators -Rights Read -Confirm:$false |
        Where-Object Action -ne 'AlreadyPresent'

    Two principals at once, without prompting, shows only what changed or failed.

.OUTPUTS
    One object per target and principal: ComputerName, Path, Scope (Root/ProtectedFolder/
    ProtectedFile), Principal, Sid, Rights, Action (Granted/AlreadyPresent/WhatIf/Failed/Skipped),
    Message.

.NOTES
    Author:        MSSQLTools
    Prerequisites: elevated PowerShell (Administrator), icacls.exe. Local machine only.
    Changes only add rights, nothing is removed. Undo per path:
        icacls <path> /remove:g *<SID>
    (removes ALL Allow ACEs of that SID on that object, including ones that existed before).
#>
function Grant-sqmVolumeAccess
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[ValidateSet('AuthenticatedUsers', 'Administrators')]
		[string[]]$Principal,
		[Parameter(Mandatory = $false)]
		[string[]]$Account,
		[Parameter(Mandatory = $false)]
		[ValidateSet('ReadAndExecute', 'Read', 'Modify', 'FullControl')]
		[string]$Rights = 'ReadAndExecute',
		[Parameter(Mandatory = $false)]
		[string[]]$DriveLetter = @('F', 'G', 'H', 'I'),
		[Parameter(Mandatory = $false)]
		[string[]]$Path,
		[Parameter(Mandatory = $false)]
		[string[]]$ExcludeDrive = @('C', 'S'),
		[Parameter(Mandatory = $false)]
		[switch]$IncludeFiles,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()

		if (-not $Principal -and -not $Account)
		{
			throw "Mindestens -Principal oder -Account angeben (z.B. -Principal AuthenticatedUsers)."
		}

		$wellKnownSid = @{
			AuthenticatedUsers = 'S-1-5-11'
			Administrators     = 'S-1-5-32-544'
		}
		$icaclsCode = @{ ReadAndExecute = 'RX'; Read = 'R'; Modify = 'M'; FullControl = 'F' }
		$needRights = [System.Security.AccessControl.FileSystemRights]$Rights

		# --- Principals zu SIDs aufloesen (sprachunabhaengig) ---
		$principals = [System.Collections.Generic.List[PSCustomObject]]::new()
		foreach ($p in @($Principal))
		{
			if (-not $p) { continue }
			$principals.Add([PSCustomObject]@{ Sid = $wellKnownSid[$p]; Input = $p })
		}
		foreach ($a in @($Account))
		{
			if (-not $a) { continue }
			try
			{
				$sidValue = if ($a -match '^S-1-\d+(-\d+)+$')
				{
					([System.Security.Principal.SecurityIdentifier]$a).Value
				}
				else
				{
					([System.Security.Principal.NTAccount]$a).Translate([System.Security.Principal.SecurityIdentifier]).Value
				}
				$principals.Add([PSCustomObject]@{ Sid = $sidValue; Input = $a })
			}
			catch
			{
				throw "Konto '$a' laesst sich nicht aufloesen: $($_.Exception.Message)"
			}
		}
		foreach ($pr in $principals)
		{
			# Anzeigename in der Sprache des Systems (z.B. "NT-AUTORITAET\Authentifizierte Benutzer")
			$display = $pr.Input
			try { $display = ([System.Security.Principal.SecurityIdentifier]$pr.Sid).Translate([System.Security.Principal.NTAccount]).Value } catch { }
			$pr | Add-Member -NotePropertyName Name -NotePropertyValue $display
		}
		$principals = @($principals | Sort-Object Sid -Unique)

		# --- Ausschluesse normalisieren, Systemlaufwerk immer dazu ---
		$systemLetter = ($env:SystemDrive -replace '[^A-Za-z]', '').ToUpper()
		$exclude = @(@($ExcludeDrive) | ForEach-Object { ("$_" -replace '[^A-Za-z]', '').ToUpper() } | Where-Object { $_ }) + $systemLetter |
			Sort-Object -Unique

		$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
			[Security.Principal.WindowsBuiltInRole]::Administrator)
		if (-not $isAdmin -and -not $WhatIfPreference)
		{
			Write-Warning "Keine erhoehte Sitzung: Aenderungen an Volume-Wurzeln und fremden Ordnern werden fehlschlagen."
		}

		Invoke-sqmLogging -Message ("Starte $functionName (Principals: {0}; Rechte: {1}; ausgeschlossen: {2})" -f
			(($principals | ForEach-Object { "$($_.Name) [$($_.Sid)]" }) -join ', '), $Rights, ($exclude -join ', ')) -FunctionName $functionName -Level "INFO"

		$skipNames = @('System Volume Information', '$RECYCLE.BIN')

		# Rechte einer ACE, generische Bits (GENERIC_ALL usw.) auf Dateirechte abgebildet
		function _AceRights
		{
			param ([System.Security.AccessControl.FileSystemAccessRule]$Ace)
			$raw = [int64]$Ace.FileSystemRights -band 0xFFFFFFFFL
			$mapped = $raw -band 0x0FFFFFFFL
			if ($raw -band 0x10000000L) { $mapped = $mapped -bor [int64][System.Security.AccessControl.FileSystemRights]::FullControl }
			if ($raw -band 0x80000000L) { $mapped = $mapped -bor [int64][System.Security.AccessControl.FileSystemRights]::Read }
			if ($raw -band 0x40000000L) { $mapped = $mapped -bor [int64][System.Security.AccessControl.FileSystemRights]::Write }
			if ($raw -band 0x20000000L) { $mapped = $mapped -bor [int64][System.Security.AccessControl.FileSystemRights]::ExecuteFile }
			return $mapped
		}

		# Hat $Sid auf dem Objekt schon eine Allow-ACE, die die Rechte abdeckt und (bei Ordnern)
		# an Unterordner und Dateien weitergegeben wird? Explizit oder geerbt ist egal.
		function _HasCoveringAce
		{
			param ([string]$LiteralPath, [string]$Sid, [bool]$IsContainer)
			$acl = Get-Acl -LiteralPath $LiteralPath -ErrorAction Stop
			$need = [int64]$needRights
			foreach ($ace in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
			{
				if ($ace.IdentityReference.Value -ne $Sid) { continue }
				if ($ace.AccessControlType -ne 'Allow') { continue }
				if (((_AceRights $ace) -band $need) -ne $need) { continue }
				if ($IsContainer)
				{
					$flags = $ace.InheritanceFlags
					if (-not ($flags -band [System.Security.AccessControl.InheritanceFlags]::ContainerInherit)) { continue }
					if (-not ($flags -band [System.Security.AccessControl.InheritanceFlags]::ObjectInherit)) { continue }
					if ($ace.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None) { continue }
				}
				return $true
			}
			return $false
		}

		# icacls /grant, sprachunabhaengig ausgewertet: Exitcode + letzte Zahl der Summenzeile
		# ("... 0 Dateien ist ein Verarbeitungsfehler aufgetreten" / "Failed processing 0 files").
		# Die Summenzeile selbst ist kein Fehler.
		function _InvokeIcaclsGrant
		{
			param ([string]$LiteralPath, [string]$Spec)
			# Abschliessender Backslash vor dem Anfuehrungszeichen wuerde unter PS 5.1 das Argument
			# zerlegen, wenn der Pfad Leerzeichen enthaelt. Laufwerkswurzeln ("F:\") bleiben.
			$arg = if ($LiteralPath.Length -gt 3) { $LiteralPath.TrimEnd('\') } else { $LiteralPath }
			$prevEap = $ErrorActionPreference
			$ErrorActionPreference = 'Continue'
			try
			{
				$out = & icacls.exe $arg '/grant' $Spec '/C' '/Q' 2>&1
				$code = $LASTEXITCODE
			}
			finally
			{
				$ErrorActionPreference = $prevEap
			}
			$lines = @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
			$failed = $null
			if ($lines.Count -gt 0)
			{
				$nums = [regex]::Matches($lines[-1], '\d+')
				if ($nums.Count -ge 2) { $failed = [int]$nums[$nums.Count - 1].Value }
			}
			$detail = @($lines | Select-Object -SkipLast 1)
			[PSCustomObject]@{ ExitCode = $code; Failed = $failed; Detail = $detail }
		}

		# Ordner (und mit -IncludeFiles Dateien) mit unterbrochener Vererbung. Eigener Stapel statt
		# Get-ChildItem -Recurse: Reparse Points werden nicht betreten, Systemordner uebersprungen,
		# ein unlesbarer Ordner bricht die Suche nicht ab.
		function _FindProtected
		{
			param ([string]$Root)
			$found = [System.Collections.Generic.List[PSCustomObject]]::new()
			$unreadable = [System.Collections.Generic.List[string]]::new()
			$reparse = 0
			$stack = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
			$stack.Push([System.IO.DirectoryInfo]::new($Root))
			while ($stack.Count -gt 0)
			{
				$dir = $stack.Pop()
				try { $children = $dir.GetDirectories() }
				catch { $unreadable.Add($dir.FullName); continue }
				foreach ($c in $children)
				{
					if ($skipNames -contains $c.Name) { continue }
					if ($c.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $reparse++; continue }
					try
					{
						if ((Get-Acl -LiteralPath $c.FullName -ErrorAction Stop).AreAccessRulesProtected)
						{
							$found.Add([PSCustomObject]@{ Path = $c.FullName; IsContainer = $true })
						}
					}
					catch { $unreadable.Add($c.FullName); continue }
					$stack.Push($c)
				}
				if ($IncludeFiles)
				{
					try { $files = $dir.GetFiles() } catch { $files = @() }
					foreach ($f in $files)
					{
						try
						{
							if ((Get-Acl -LiteralPath $f.FullName -ErrorAction Stop).AreAccessRulesProtected)
							{
								$found.Add([PSCustomObject]@{ Path = $f.FullName; IsContainer = $false })
							}
						}
						catch { $unreadable.Add($f.FullName) }
					}
				}
			}
			[PSCustomObject]@{ Items = $found; Unreadable = $unreadable; ReparsePoints = $reparse }
		}

		function _NewResult
		{
			param ($TargetPath, $Scope, $Pr, $Action, $Message)
			[PSCustomObject]@{
				ComputerName = $env:COMPUTERNAME
				Path         = $TargetPath
				Scope        = $Scope
				Principal    = $(if ($Pr) { $Pr.Name } else { '' })
				Sid          = $(if ($Pr) { $Pr.Sid } else { '' })
				Rights       = $Rights
				Action       = $Action
				Message      = $Message
			}
		}

		# Ein Objekt fuer einen Principal pruefen und ggf. berechtigen
		function _GrantOne
		{
			param ([string]$TargetPath, [bool]$IsContainer, [string]$Scope, $Pr)
			try
			{
				if (_HasCoveringAce -LiteralPath $TargetPath -Sid $Pr.Sid -IsContainer $IsContainer)
				{
					return (_NewResult $TargetPath $Scope $Pr 'AlreadyPresent' 'Recht bereits vorhanden, nichts geaendert.')
				}
				$spec = if ($IsContainer) { "*$($Pr.Sid):(OI)(CI)$($icaclsCode[$Rights])" } else { "*$($Pr.Sid):$($icaclsCode[$Rights])" }
				if (-not $PSCmdlet.ShouldProcess($TargetPath, "Allow $($Pr.Name) = $Rights ($Scope)"))
				{
					return (_NewResult $TargetPath $Scope $Pr 'WhatIf' "icacls `"$TargetPath`" /grant $spec")
				}
				$r = _InvokeIcaclsGrant -LiteralPath $TargetPath -Spec $spec
				foreach ($line in $r.Detail)
				{
					Invoke-sqmLogging -Message "  icacls: $line" -FunctionName $functionName -Level "WARNING"
				}
				$ok = $r.ExitCode -eq 0 -and (_HasCoveringAce -LiteralPath $TargetPath -Sid $Pr.Sid -IsContainer $IsContainer)
				if ($ok)
				{
					$msg = 'Gesetzt und nachgelesen.'
					if ($r.Failed) { $msg += " icacls meldet $($r.Failed) Fehler bei der Weitergabe (siehe Log)." }
					return (_NewResult $TargetPath $Scope $Pr 'Granted' $msg)
				}
				# icacls /C liefert auch bei "Zugriff verweigert" Exitcode 0 - massgeblich ist das Nachlesen
				$msg = if ($r.Detail) { 'icacls: ' + ($r.Detail -join ' | ') } else { "Recht nach icacls (Exitcode $($r.ExitCode)) nicht vorhanden." }
				return (_NewResult $TargetPath $Scope $Pr 'Failed' $msg)
			}
			catch
			{
				if ($EnableException) { throw }
				return (_NewResult $TargetPath $Scope $Pr 'Failed' $_.Exception.Message)
			}
		}
	}

	process
	{
		# --- Ziele bestimmen ---
		$candidates = if ($Path)
		{
			@($Path | Where-Object { $_ })
		}
		else
		{
			@($DriveLetter | ForEach-Object { ("$_" -replace '[^A-Za-z]', '').ToUpper() } | Where-Object { $_ } | ForEach-Object { '{0}:\' -f $_ })
		}

		$targets = [System.Collections.Generic.List[string]]::new()
		foreach ($cand in $candidates)
		{
			$full = $cand
			try { $full = [System.IO.Path]::GetFullPath($cand) } catch { }
			if ($full -match '^[A-Za-z]:\\?$') { $full = $full.Substring(0, 2) + '\' }
			else { $full = $full.TrimEnd('\') }
			$letter = if ($full -match '^([A-Za-z]):') { $Matches[1].ToUpper() } else { '' }

			if ($letter -and $letter -eq $systemLetter)
			{
				$results.Add((_NewResult $full 'Root' $null 'Skipped' 'Systemlaufwerk - wird nie geaendert.'))
				continue
			}
			if ($letter -and ($exclude -contains $letter))
			{
				$results.Add((_NewResult $full 'Root' $null 'Skipped' "Laufwerk $letter ist ausgeschlossen (-ExcludeDrive)."))
				continue
			}
			if (-not (Test-Path -LiteralPath $full -PathType Container))
			{
				$results.Add((_NewResult $full 'Root' $null 'Skipped' 'Existiert nicht oder ist kein Ordner.'))
				continue
			}
			if ($letter)
			{
				$fs = $null
				try { $fs = ([System.IO.DriveInfo]::new($letter)).DriveFormat } catch { }
				if ($fs -and $fs -notin 'NTFS', 'ReFS')
				{
					$results.Add((_NewResult $full 'Root' $null 'Skipped' "Dateisystem $fs unterstuetzt keine NTFS-Rechte."))
					continue
				}
			}
			if (-not $targets.Contains($full)) { $targets.Add($full) }
		}

		foreach ($target in $targets)
		{
			Invoke-sqmLogging -Message "Bearbeite '$target'" -FunctionName $functionName -Level "INFO"

			# 1) Wurzel: vererbbare ACE, Windows gibt sie an alles mit aktiver Vererbung weiter
			foreach ($pr in $principals)
			{
				Write-Progress -Activity $functionName -Status "$target - $($pr.Name)"
				$results.Add((_GrantOne -TargetPath $target -IsContainer $true -Scope 'Root' -Pr $pr))
			}

			# 2) Ordner/Dateien mit unterbrochener Vererbung explizit nachziehen
			Write-Progress -Activity $functionName -Status "$target - suche unterbrochene Vererbung"
			$scan = _FindProtected -Root $target
			if ($scan.ReparsePoints) { Invoke-sqmLogging -Message "  $($scan.ReparsePoints) Reparse Point(s) (Junction/Symlink/Mountpoint) nicht betreten." -FunctionName $functionName -Level "INFO" }
			foreach ($u in $scan.Unreadable)
			{
				$results.Add((_NewResult $u 'ProtectedFolder' $null 'Failed' 'ACL/Inhalt nicht lesbar - Vererbungsstatus unbekannt.'))
			}
			foreach ($item in $scan.Items)
			{
				$scope = if ($item.IsContainer) { 'ProtectedFolder' } else { 'ProtectedFile' }
				foreach ($pr in $principals)
				{
					Write-Progress -Activity $functionName -Status "$($item.Path) - $($pr.Name)"
					$results.Add((_GrantOne -TargetPath $item.Path -IsContainer $item.IsContainer -Scope $scope -Pr $pr))
				}
			}
		}
		Write-Progress -Activity $functionName -Completed
	}

	end
	{
		foreach ($r in $results)
		{
			$level = switch ($r.Action) { 'Failed' { 'ERROR' } 'Skipped' { 'WARNING' } default { 'INFO' } }
			Invoke-sqmLogging -Message ("{0} [{1}] {2}: {3} - {4}" -f $r.Action, $r.Scope, $r.Path, $r.Principal, $r.Message) -FunctionName $functionName -Level $level
		}
		$counts = ($results | Group-Object Action | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
		Invoke-sqmLogging -Message "Fertig: $counts" -FunctionName $functionName -Level "INFO"
		Write-Verbose "Fertig: $counts"
		$results
	}
}
