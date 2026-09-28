<#
.SYNOPSIS
    Copies NTFS permissions (ACLs) from a source path to a destination path.

.DESCRIPTION
    Reads the explicit NTFS permissions for each file system object (folder/file) below
    the source path and applies them to the corresponding object below the destination path.
    The target structure must already exist (exception: with -CreateMissingFolders, missing
    target folders are created automatically).

.PARAMETER SourcePath
    Source path (e.g. "D:\" or "D:\Data").

.PARAMETER DestinationPath
    Destination path (e.g. "E:\" or "E:\Data").

.PARAMETER Recurse
    Recursive traversal of all subfolders and files.

.PARAMETER CreateMissingFolders
    Automatically creates missing target folders (directories only, not files).
    Files missing at the destination are skipped.
    Implies -Recurse: creating the missing folder structure only makes sense for the whole
    tree. Without it, only the top-level folder itself would be processed.

.PARAMETER IncludeSystemAndHidden
    Includes hidden and system objects in the processing.

.EXAMPLE
    Copy-sqmNTFSPermissions -SourcePath "D:\" -DestinationPath "E:\" -Recurse
    Copies all permissions from D: to E: (recursively).

.EXAMPLE
    Copy-sqmNTFSPermissions -SourcePath "D:\Daten" -DestinationPath "E:\Daten" -Recurse -CreateMissingFolders
    Copies permissions and creates missing target folders.

.NOTES
    Requires administrative rights (Get-Acl / Set-Acl).
    Access errors generate warnings; processing continues.
#>
function Copy-sqmNTFSPermissions {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$SourcePath,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$DestinationPath,

        [switch]$Recurse,
        [switch]$CreateMissingFolders,
        [switch]$IncludeSystemAndHidden
    )

    begin {
        # Quellpfad auf den vollstaendigen Pfad normalisieren. Der relative Pfad jedes Objekts
        # wird per Substring aus FullName gebildet; ein relativ angegebener Quellpfad ("Daten")
        # ist kuerzer als FullName ("D:\Daten") und fuehrte dazu, dass die komplette
        # Verzeichniskette unter dem Ziel nachgebaut wurde.
        $SourcePath = (Get-Item -LiteralPath $SourcePath -Force).FullName.TrimEnd('\')
        $DestinationPath = [System.IO.Path]::GetFullPath($DestinationPath)

        # Fehlende Ordner anlegen heisst, die Struktur des ganzen Baums anlegen. Ohne -Recurse
        # wurde nur der oberste Ordner verarbeitet, und keiner der Unterordner entstand.
        if ($CreateMissingFolders -and -not $Recurse) {
            Write-Verbose "-CreateMissingFolders schliesst -Recurse ein: der gesamte Baum wird verarbeitet."
            $Recurse = [switch]$true
        }
        if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
            if ($CreateMissingFolders) {
                if ($PSCmdlet.ShouldProcess($DestinationPath, "Erstelle Zielverzeichnis")) {
                    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
                    Write-Verbose "Zielverzeichnis '$DestinationPath' wurde erstellt."
                }
            } else {
                throw "Zielpfad '$DestinationPath' existiert nicht. Verwenden Sie -CreateMissingFolders."
            }
        }

        if ($Recurse) {
            # -LiteralPath: mit -Path werden [ ] in Ordnernamen als Wildcard gelesen
            $allItems = @(Get-Item -LiteralPath $SourcePath -Force:$IncludeSystemAndHidden) +
                        @(Get-ChildItem -LiteralPath $SourcePath -Recurse -Force:$IncludeSystemAndHidden -ErrorAction SilentlyContinue)
        } else {
            $allItems = @(Get-Item -LiteralPath $SourcePath -Force:$IncludeSystemAndHidden)
        }

        $total   = $allItems.Count
        $current = 0
    }

    process {
        foreach ($sourceItem in $allItems) {
            $current++
            $relativePath = $sourceItem.FullName.Substring($SourcePath.Length).TrimStart('\')
            $destItemPath = if ($relativePath) { $DestinationPath.TrimEnd('\') + '\' + $relativePath } else { $DestinationPath }

            Write-Progress -Activity "Kopiere NTFS-Berechtigungen" `
                           -Status "$current von $total : $relativePath" `
                           -PercentComplete (($current / $total) * 100)

            if ($sourceItem.PSIsContainer) {
                if (-not (Test-Path -LiteralPath $destItemPath -PathType Container)) {
                    if ($CreateMissingFolders) {
                        if ($PSCmdlet.ShouldProcess($destItemPath, "Erstelle Ordner")) {
                            try {
                                New-Item -ItemType Directory -Path $destItemPath -Force -ErrorAction Stop | Out-Null
                                Write-Verbose "Ordner '$destItemPath' erstellt."
                            } catch {
                                Write-Warning "Fehler beim Erstellen von '$destItemPath': $($_.Exception.Message)"
                                continue
                            }
                        }
                    } else {
                        Write-Warning "Zielordner '$destItemPath' existiert nicht. Ueberspringe (-CreateMissingFolders verwenden)."
                        continue
                    }
                }
            } else {
                if (-not (Test-Path -LiteralPath $destItemPath -PathType Leaf)) {
                    Write-Warning "Zieldatei '$destItemPath' existiert nicht. Ueberspringe."
                    continue
                }
            }

            try {
                $acl = Get-Acl -LiteralPath $sourceItem.FullName -ErrorAction Stop
                if ($PSCmdlet.ShouldProcess($destItemPath, "Setze ACL von '$($sourceItem.FullName)'")) {
                    Set-Acl -LiteralPath $destItemPath -AclObject $acl -ErrorAction Stop
                    Write-Verbose "ACL kopiert: $relativePath"
                }
            } catch {
                Write-Warning "Fehler bei '$($sourceItem.FullName)' -> '$destItemPath': $($_.Exception.Message)"
            }
        }
        Write-Progress -Activity "Kopiere NTFS-Berechtigungen" -Completed
    }

    end {
        Write-Host "Abgeschlossen. $total Elemente verarbeitet." -ForegroundColor Green
    }
}
