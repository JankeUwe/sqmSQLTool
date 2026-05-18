<#
.SYNOPSIS
    Kopiert NTFS-Berechtigungen (ACLs) von einem Quellpfad auf einen Zielpfad.

.DESCRIPTION
    Liest fuer jedes Dateisystemobjekt (Ordner/Datei) unterhalb des Quellpfades die
    expliziten NTFS-Berechtigungen aus und wendet sie auf das entsprechende Objekt
    unterhalb des Zielpfades an. Voraussetzung ist, dass die Zielstruktur bereits
    existiert (Ausnahme: mit -CreateMissingFolders werden fehlende Zielordner angelegt).

.PARAMETER SourcePath
    Quellpfad (z.B. "D:\" oder "D:\Daten").

.PARAMETER DestinationPath
    Zielpfad (z.B. "E:\" oder "E:\Daten").

.PARAMETER Recurse
    Rekursiver Durchlauf aller Unterordner und Dateien.

.PARAMETER CreateMissingFolders
    Erstellt fehlende Zielordner automatisch (nur fuer Verzeichnisse, nicht fuer Dateien).
    Dateien, die im Ziel fehlen, werden uebersprungen.

.PARAMETER IncludeSystemAndHidden
    Bezieht versteckte und Systemobjekte in die Verarbeitung ein.

.EXAMPLE
    Copy-sqmNTFSPermissions -SourcePath "D:\" -DestinationPath "E:\" -Recurse
    Kopiert alle Berechtigungen von D: nach E: (rekursiv).

.EXAMPLE
    Copy-sqmNTFSPermissions -SourcePath "D:\Daten" -DestinationPath "E:\Daten" -Recurse -CreateMissingFolders
    Kopiert Berechtigungen und legt fehlende Zielordner an.

.NOTES
    Erfordert administrative Rechte (Get-Acl / Set-Acl).
    Bei Zugriffsfehlern werden Warnungen ausgegeben, der Vorgang wird fortgesetzt.
#>
function Copy-sqmNTFSPermissions {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$SourcePath,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$DestinationPath,

        [switch]$Recurse,
        [switch]$CreateMissingFolders,
        [switch]$IncludeSystemAndHidden
    )

    begin {
        $DestinationPath = [System.IO.Path]::GetFullPath($DestinationPath)
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
            $allItems = @(Get-Item -Path $SourcePath -Force:$IncludeSystemAndHidden) +
                        @(Get-ChildItem -Path $SourcePath -Recurse -Force:$IncludeSystemAndHidden -ErrorAction SilentlyContinue)
        } else {
            $allItems = @(Get-Item -Path $SourcePath -Force:$IncludeSystemAndHidden)
        }

        $total   = $allItems.Count
        $current = 0
    }

    process {
        foreach ($sourceItem in $allItems) {
            $current++
            $relativePath = $sourceItem.FullName.Substring($SourcePath.TrimEnd('\').Length).TrimStart('\')
            $destItemPath = Join-Path -Path $DestinationPath -ChildPath $relativePath

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
                $acl = Get-Acl -Path $sourceItem.FullName -ErrorAction Stop
                if ($PSCmdlet.ShouldProcess($destItemPath, "Setze ACL von '$($sourceItem.FullName)'")) {
                    Set-Acl -Path $destItemPath -AclObject $acl -ErrorAction Stop
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
