<#
.SYNOPSIS
    Lists all members of an Active Directory group.

.DESCRIPTION
    Queries an Active Directory group and returns all members with extended information
    (Name, SamAccountName, Type, Enabled, Email, Department, Title, LastLogon).

    Uses ADSI (no RSAT required) with automatic range retrieval for large groups (>1500 members).
    Supports recursive group expansion (nested group resolution).

    Results are saved as TXT report and CSV file in the specified directory.
    The function also returns an object with the detail data and file paths.

.PARAMETER GroupName
    Name of the AD group(s). Pipeline-capable.
    Format: "GroupName" or "DOMAIN\GroupName" or "CN=GroupName,DC=domain,DC=local"

.PARAMETER Domain
    Optional: Specify the Active Directory domain (e.g., "FITS.LOCAL", "FITS", or "example.com").
    If not specified, attempts to auto-detect from current domain.

.PARAMETER DomainController
    Optional: Specific domain controller to query (e.g., "DC01.fits.local").
    If not specified, uses domain auto-detection.

.PARAMETER Recursive
    If specified, recursively expand nested groups (resolves all transitive members).
    Default: OFF (only direct members).

.PARAMETER OutputPath
    Output directory for report files. Default: $env:ProgramData\sqmSQLTool\ADReports

.PARAMETER NoOpen
    If specified, do not open the report file after creation.

.PARAMETER PassThru
    Return the result object (default behavior).

.PARAMETER ContinueOnError
    Continue on error for a group (otherwise the error is thrown).

.PARAMETER EnableException
    Throw exceptions immediately (overrides ContinueOnError).

.PARAMETER Confirm
    Request confirmation before writing files.

.PARAMETER WhatIf
    Shows which files would be created without actually writing them.

.EXAMPLE
    Get-sqmADGroupMembers -GroupName "DL_SQL_Admins"

.EXAMPLE
    Get-sqmADGroupMembers -GroupName "DL_SQL_Admins" -Domain "FITS.LOCAL"

.EXAMPLE
    Get-sqmADGroupMembers -GroupName "Domain Admins", "Enterprise Admins" -Domain "FITS" -OutputPath "D:\Reports"

.EXAMPLE
    Get-sqmADGroupMembers -GroupName "DL_SQL_Admins" -Recursive -DomainController "DC01.fits.local"

.NOTES
    Author:       MSSQLTools
    Prerequisites: Invoke-sqmLogging
    Default output path: $env:ProgramData\sqmSQLTool\ADReports
    AD-Method: ADSI (no RSAT required; works on all Windows systems with AD access)
    Range Retrieval: Automatic for groups with >1500 members
#>
function Get-sqmADGroupMembers
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$GroupName,

        [Parameter(Mandatory = $false)]
        [string]$Domain,

        [Parameter(Mandatory = $false)]
        [string]$DomainController,

        [Parameter(Mandatory = $false)]
        [switch]$Recursive,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath = "$env:ProgramData\sqmSQLTool\ADReports",

        [Parameter(Mandatory = $false)]
        [switch]$NoOpen,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru,

        [Parameter(Mandatory = $false)]
        [switch]$ContinueOnError,

        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name
        $allGroupResults = [System.Collections.Generic.List[PSCustomObject]]::new()

        # Test ADSI connectivity
        try
        {
            $null = [ADSI]"LDAP://RootDSE"
            Invoke-sqmLogging -Message "ADSI-Verbindung erfolgreich." -FunctionName $functionName -Level "INFO"
        }
        catch
        {
            $errMsg = "Fehler: ADSI-Verbindung fehlgeschlagen - kein Domain Controller erreichbar. $_"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
            throw $errMsg
        }

        Invoke-sqmLogging -Message "Starte $functionName. OutputPath: $OutputPath | Recursive: $Recursive" -FunctionName $functionName -Level "INFO"
    }

    process
    {
        foreach ($group in $GroupName)
        {
            $detailRows = [System.Collections.Generic.List[PSCustomObject]]::new()

            try
            {
                Invoke-sqmLogging -Message "[$group] Abfrage wird gestartet..." -FunctionName $functionName -Level "INFO"

                # Bestimme Domain
                $targetDomain = $Domain
                if (-not $targetDomain)
                {
                    try
                    {
                        $targetDomain = ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()).Name
                    }
                    catch
                    {
                        $targetDomain = $env:USERDNSDOMAIN
                    }
                }

                Invoke-sqmLogging -Message "[$group] Verwende Domain: $targetDomain" -FunctionName $functionName -Level "VERBOSE"

                # Gruppe suchen — mehrere Methoden
                $groupEntry = $null
                $cleanGroup = $group -replace '^[^\\]*\\', ''  # Entferne DOMAIN\-Präfix falls vorhanden

                # Methode 1: Direkter WinNT-Pfad (wie SQL Server HelpLogin)
                try
                {
                    $groupEntry = [ADSI]"WinNT://$targetDomain/$cleanGroup,group"
                    if ($groupEntry.Name)
                    {
                        Invoke-sqmLogging -Message "[$group] Gruppe gefunden via WinNT (Methode 1: $targetDomain)." -FunctionName $functionName -Level "VERBOSE"
                    }
                    else
                    {
                        $groupEntry = $null
                    }
                }
                catch
                {
                    Invoke-sqmLogging -Message "[$group] WinNT-Methode fehlgeschlagen, versuche DirectorySearcher..." -FunctionName $functionName -Level "VERBOSE"
                    $groupEntry = $null
                }

                # Methode 2: DirectorySearcher mit sAMAccountName
                if (-not $groupEntry)
                {
                    try
                    {
                        $rootEntry = if ($targetDomain) {
                            [ADSI]"LDAP://$targetDomain/RootDSE"
                        } else {
                            [ADSI]"LDAP://RootDSE"
                        }

                        if ($rootEntry.distinguishedName)
                        {
                            [System.DirectoryServices.DirectorySearcher]$searcher = [System.DirectoryServices.DirectorySearcher]::new($rootEntry)
                            $searcher.Filter = "(sAMAccountName=$cleanGroup)"
                            $searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
                            $searchResult = $searcher.FindOne()

                            if ($searchResult)
                            {
                                $groupEntry = $searchResult.GetDirectoryEntry()
                                Invoke-sqmLogging -Message "[$group] Gruppe gefunden via DirectorySearcher (Methode 2: $targetDomain)." -FunctionName $functionName -Level "VERBOSE"
                            }
                        }
                    }
                    catch
                    {
                        Invoke-sqmLogging -Message "[$group] DirectorySearcher fehlgeschlagen: $_" -FunctionName $functionName -Level "VERBOSE"
                    }
                }

                # Methode 3: Direkter LDAP-Lookup (falls Gruppe mit CN= angegeben ist)
                if (-not $groupEntry -and $group -like "*=*")
                {
                    try
                    {
                        $ldapPath = if ($group -like "LDAP://*") { $group } else { "LDAP://$targetDomain/$group" }
                        $groupEntry = [ADSI]$ldapPath
                        if ($groupEntry.Name)
                        {
                            Invoke-sqmLogging -Message "[$group] Gruppe gefunden via LDAP DN (Methode 3)." -FunctionName $functionName -Level "VERBOSE"
                        }
                        else
                        {
                            $groupEntry = $null
                        }
                    }
                    catch
                    {
                        Invoke-sqmLogging -Message "[$group] LDAP DN-Lookup fehlgeschlagen: $_" -FunctionName $functionName -Level "VERBOSE"
                        $groupEntry = $null
                    }
                }

                if (-not $groupEntry)
                {
                    $warnMsg = "[$group] Gruppe nicht gefunden oder nicht zugreifbar."
                    Invoke-sqmLogging -Message $warnMsg -FunctionName $functionName -Level "WARNING"
                    $allGroupResults.Add([PSCustomObject]@{
                            GroupName   = $group
                            Timestamp   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                            MemberCount = 0
                            Members     = @()
                            OutputPath  = $OutputPath
                            TxtFile     = $null
                            CsvFile     = $null
                            Status      = 'Warning'
                            Message     = $warnMsg
                        })
                    continue
                }

                $groupDN = $groupEntry.Properties['distinguishedName'][0]
                Invoke-sqmLogging -Message "[$group] Gruppe gefunden: DN=$groupDN" -FunctionName $functionName -Level "VERBOSE"

                # Members abrufen (unterschiedlich für WinNT vs LDAP)
                $memberDNs = [System.Collections.Generic.List[string]]::new()

                if ($groupEntry)
                {
                    # Bestimme ob WinNT oder LDAP basierend auf Path
                    $path = $groupEntry.psbase.Path
                    $isWinNT = $path -like "WinNT://*"
                    $isLDAP = $path -like "LDAP://*"

                    Invoke-sqmLogging -Message "[$group] Member-Abruf: Typ=$([System.IO.Path]::GetExtension($path)) (WinNT=$isWinNT, LDAP=$isLDAP)" -FunctionName $functionName -Level "VERBOSE"

                    # WinNT: Members() Methode — direkt die Member-Objekte verarbeiten
                    if ($isWinNT)
                    {
                        try
                        {
                            $members = $groupEntry.psbase.Invoke("Members")
                            foreach ($member in $members)
                            {
                                try
                                {
                                    # WinNT Member ist bereits ein ADSI-Objekt, nicht eine DN
                                    # Extrahiere Informationen direkt
                                    $samAccount = $member.name.Value
                                    $displayName = $member.displayName.Value

                                    # Objekt-Typ bestimmen
                                    $objectClass = $member.objectClass.Value
                                    if ($objectClass -is [array]) { $objectClass = $objectClass[-1] }

                                    # Status aus userAccountControl ermitteln
                                    $uacValue = $member.userAccountControl.Value
                                    $isEnabled = $true
                                    if ($uacValue) { $isEnabled = (($uacValue -band 2) -eq 0) }

                                    # LastLogon
                                    $lastLogon = $null
                                    $llts = $member.lastLogonTimestamp.Value
                                    if ($llts) {
                                        try { $lastLogon = [DateTime]::FromFileTime($llts) } catch { }
                                    }

                                    # Zusammenstellung der Member-Info
                                    $memberPath = $member.psbase.Path
                                    $rowObj = [PSCustomObject]@{
                                        GroupName         = $group
                                        SamAccountName    = $samAccount
                                        DisplayName       = $displayName
                                        ObjectClass       = $objectClass
                                        Enabled           = $isEnabled
                                        Email             = $member.mail.Value
                                        Department        = $member.department.Value
                                        Title             = $member.title.Value
                                        LastLogon         = $lastLogon
                                        DistinguishedName = $memberPath
                                    }
                                    $detailRows.Add($rowObj)
                                }
                                catch
                                {
                                    Invoke-sqmLogging -Message "[$group] Fehler beim Verarbeiten von WinNT-Member: $_" -FunctionName $functionName -Level "WARNING"
                                }
                            }
                            Invoke-sqmLogging -Message "[$group] $($detailRows.Count) Members via WinNT.Members()" -FunctionName $functionName -Level "VERBOSE"
                        }
                        catch
                        {
                            Invoke-sqmLogging -Message "[$group] WinNT Members()-Abruf fehlgeschlagen: $_" -FunctionName $functionName -Level "WARNING"
                        }
                    }
                    # LDAP: Range-Retrieval
                    else
                    {
                        $rangeStart = 0
                        $rangeSize = 1500

                        do
                        {
                            $rangeEnd = $rangeStart + $rangeSize - 1

                            try
                            {
                                $attrs = $groupEntry.psbase.Properties
                                $foundAttr = $null

                                # Versuche das Bereichs-Attribut zu lesen
                                foreach ($attr in $attrs.PropertyNames)
                                {
                                    if ($attr -like "member;range=*" -or $attr -eq "member")
                                    {
                                        $foundAttr = $attr
                                        break
                                    }
                                }

                                if (-not $foundAttr)
                                {
                                    # Berange das member-Attribut manuell
                                    $members = $groupEntry.psbase.InvokeGet("member;range=$rangeStart-$rangeEnd")
                                    if (-not $members)
                                    {
                                        # Try ohne Range für kleine Gruppen
                                        $members = $groupEntry.psbase.InvokeGet("member")
                                    }
                                }
                                else
                                {
                                    $members = $attrs[$foundAttr]
                                }

                                if ($members -and $members.Count -gt 0)
                                {
                                    foreach ($dn in $members)
                                    {
                                        $memberDNs.Add($dn)
                                    }

                                    # Pruefen ob wir das Ende erreicht haben
                                    if ($members.Count -lt $rangeSize)
                                    {
                                        break
                                    }

                                    $rangeStart = $rangeEnd + 1
                                }
                                else
                                {
                                    break
                                }
                            }
                            catch
                            {
                                # Fallback: einfach alle member ohne Range abrufen
                                $members = $groupEntry.psbase.InvokeGet("member")
                                if ($members)
                                {
                                    foreach ($dn in $members)
                                    {
                                        $memberDNs.Add($dn)
                                    }
                                }
                                break
                            }
                        }
                        while ($true)
                    }
                }

                Invoke-sqmLogging -Message "[$group] $($memberDNs.Count) Members gefunden." -FunctionName $functionName -Level "INFO"

                # Members verarbeiten
                if ($Recursive)
                {
                    # Recursive: nested groups auflösen
                    $processedGroups = [System.Collections.Generic.HashSet[string]]::new()
                    $processedGroups.Add($groupDN) | Out-Null

                    foreach ($memberDN in $memberDNs)
                    {
                        _ProcessMemberRecursive -MemberDN $memberDN -GroupPath $group -AllRows $detailRows `
                            -ProcessedGroups $processedGroups -FunctionName $functionName
                    }
                }
                else
                {
                    # Non-recursive: nur direkte Members
                    foreach ($memberDN in $memberDNs)
                    {
                        $details = _GetMemberInfo -MemberDN $memberDN
                        if ($details)
                        {
                            $rowObj = [PSCustomObject]@{
                                GroupName         = $group
                                SamAccountName    = $details.SamAccountName
                                DisplayName       = $details.DisplayName
                                ObjectClass       = $details.ObjectClass
                                Enabled           = $details.Enabled
                                Email             = $details.Email
                                Department        = $details.Department
                                Title             = $details.Title
                                LastLogon         = $details.LastLogon
                                DistinguishedName = $details.DistinguishedName
                            }
                            $detailRows.Add($rowObj)
                        }
                    }
                }

                # Output-Dateien schreiben
                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                $datestamp = Get-Date -Format 'yyyy-MM-dd'
                $safeGroup = $group -replace '[\\/:*?"<>|]', '_'
                $txtFile = Join-Path $OutputPath "ADGroupMembers_${safeGroup}_${datestamp}.txt"
                $csvFile = Join-Path $OutputPath "ADGroupMembers_${safeGroup}_${datestamp}.csv"

                if ($PSCmdlet.ShouldProcess($group, "Erstelle Bericht in $OutputPath"))
                {
                    # Verzeichnis anlegen
                    if (-not (Test-Path $OutputPath))
                    {
                        New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
                        Invoke-sqmLogging -Message "Verzeichnis $OutputPath wurde erstellt." -FunctionName $functionName -Level "INFO"
                    }

                    # TXT-Bericht
                    $lines = [System.Collections.Generic.List[string]]::new()
                    $lines.Add("# sqmSQLTool - www.powershelldba.de")
                    $lines.Add("# ================================================================")
                    $lines.Add("# sqmSQLTool - AD Group Members Report")
                    $lines.Add("# Gruppe    : $group")
                    $lines.Add("# DN        : $groupDN")
                    $lines.Add("# Erstellt  : $timestamp")
                    $lines.Add("# Rekursiv  : $(if ($Recursive) { 'Ja' } else { 'Nein' })")
                    $lines.Add("# Members   : $($detailRows.Count)")
                    $lines.Add("# ================================================================")
                    $lines.Add("")
                    $lines.Add(("{0,-30} {1,-25} {2,-15} {3,-8} {4,-30}" -f
                            'SamAccountName', 'DisplayName', 'Type', 'Enabled', 'Email'))
                    $lines.Add(("-" * 110))

                    foreach ($row in ($detailRows | Sort-Object SamAccountName))
                    {
                        $enabledStr = if ($row.Enabled) { 'Ja' } else { 'Nein' }
                        $lines.Add(("{0,-30} {1,-25} {2,-15} {3,-8} {4,-30}" -f
                                $row.SamAccountName, $row.DisplayName, $row.ObjectClass, $enabledStr, $row.Email))
                    }

                    $lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force

                    # CSV-Datei (flach: eine Zeile pro Member)
                    $detailRows | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

                    Invoke-sqmLogging -Message "[$group] Bericht erstellt: $txtFile" -FunctionName $functionName -Level "INFO"
                }
                else
                {
                    Invoke-sqmLogging -Message "[$group] WhatIf: Berichtsdateien wuerden erstellt werden." -FunctionName $functionName -Level "VERBOSE"
                    $txtFile = $null
                    $csvFile = $null
                }

                # Ergebnisobjekt
                $result = [PSCustomObject]@{
                    GroupName   = $group
                    Timestamp   = $timestamp
                    MemberCount = $detailRows.Count
                    Members     = $detailRows
                    OutputPath  = $OutputPath
                    TxtFile     = $txtFile
                    CsvFile     = $csvFile
                    Status      = 'OK'
                }
                $allGroupResults.Add($result)
            }
            catch
            {
                $errMsg = "Fehler bei Gruppe '$group': $($_.Exception.Message)"
                Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
                $allGroupResults.Add([PSCustomObject]@{
                        GroupName   = $group
                        Timestamp   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        MemberCount = 0
                        Members     = $null
                        OutputPath  = $OutputPath
                        TxtFile     = $null
                        CsvFile     = $null
                        Status      = 'Error'
                        Message     = $errMsg
                    })
                if ($EnableException) { throw }
                if (-not $ContinueOnError) { throw }
            }
        }
    }

    end
    {
        Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allGroupResults.Count) Gruppen verarbeitet." -FunctionName $functionName -Level "INFO"

        # Gib Ergebnisse IMMER zurück
        return $allGroupResults
    }
}

# ==============================================================================
# Helper-Funktion: Abrufen von Benutzerinformationen
# ==============================================================================
function _GetMemberInfo
{
    param([string]$MemberDN)

    try
    {
        $memberEntry = [ADSI]"LDAP://$MemberDN"

        # Objekt-Typ bestimmen
        $objectClass = $memberEntry.objectClass.Value
        if ($objectClass -is [array])
        {
            $objectClass = $objectClass[-1]
        }

        # Status aus userAccountControl ermitteln
        $uacValue = $memberEntry.userAccountControl.Value
        $isEnabled = $true
        if ($uacValue)
        {
            $isEnabled = (($uacValue -band 2) -eq 0)  # Bit 1 (0x0002) ist "disabled"
        }

        # LastLogon/lastLogonTimestamp
        $lastLogon = $null
        $llts = $memberEntry.lastLogonTimestamp.Value
        if ($llts)
        {
            try
            {
                $lastLogon = [DateTime]::FromFileTime($llts)
            }
            catch
            {
                $lastLogon = $null
            }
        }

        [PSCustomObject]@{
            SamAccountName    = $memberEntry.sAMAccountName.Value
            DisplayName       = $memberEntry.displayName.Value
            ObjectClass       = $objectClass
            Enabled           = $isEnabled
            Email             = $memberEntry.mail.Value
            Department        = $memberEntry.department.Value
            Title             = $memberEntry.title.Value
            LastLogon         = $lastLogon
            DistinguishedName = $MemberDN
        }
    }
    catch
    {
        return $null
    }
}

# ==============================================================================
# Helper-Funktion fuer rekursive Gruppenerweiterung
# ==============================================================================
function _ProcessMemberRecursive
{
    param(
        [string]$MemberDN,
        [string]$GroupPath,
        [System.Collections.Generic.List[PSCustomObject]]$AllRows,
        [System.Collections.Generic.HashSet[string]]$ProcessedGroups,
        [string]$FunctionName
    )

    if ($ProcessedGroups.Contains($MemberDN))
    {
        return
    }

    try
    {
        $memberEntry = [ADSI]"LDAP://$MemberDN"

        # Typ bestimmen
        $objectClass = $memberEntry.objectClass.Value
        if ($objectClass -is [array])
        {
            $objectClass = $objectClass[-1]
        }

        # Status bestimmen
        $uacValue = $memberEntry.userAccountControl.Value
        $isEnabled = $true
        if ($uacValue)
        {
            $isEnabled = (($uacValue -band 2) -eq 0)
        }

        # LastLogon
        $lastLogon = $null
        $llts = $memberEntry.lastLogonTimestamp.Value
        if ($llts)
        {
            try
            {
                $lastLogon = [DateTime]::FromFileTime($llts)
            }
            catch
            {
                $lastLogon = $null
            }
        }

        # Zur Liste hinzufuegen
        $AllRows.Add([PSCustomObject]@{
                GroupName         = $GroupPath
                SamAccountName    = $memberEntry.sAMAccountName.Value
                DisplayName       = $memberEntry.displayName.Value
                ObjectClass       = $objectClass
                Enabled           = $isEnabled
                Email             = $memberEntry.mail.Value
                Department        = $memberEntry.department.Value
                Title             = $memberEntry.title.Value
                LastLogon         = $lastLogon
                DistinguishedName = $MemberDN
            })

        # Wenn Gruppe: rekursiv verarbeiten
        if ($objectClass -eq 'group')
        {
            $ProcessedGroups.Add($MemberDN) | Out-Null

            # Member dieser Gruppe abrufen
            $searcher = [adsisearcher]"(objectClass=*)"
            $searcher.SearchRoot = [ADSI]"LDAP://$MemberDN"
            $searcher.PropertiesToLoad.Clear()
            $searcher.PropertiesToLoad.Add("member") | Out-Null

            $groupResult = $searcher.FindOne()
            if ($groupResult -and $groupResult.Properties['member'].Count -gt 0)
            {
                foreach ($subMemberDN in $groupResult.Properties['member'])
                {
                    _ProcessMemberRecursive -MemberDN $subMemberDN -GroupPath "$GroupPath > $($memberEntry.sAMAccountName.Value)" `
                        -AllRows $AllRows -ProcessedGroups $ProcessedGroups -FunctionName $FunctionName
                }
            }
        }
    }
    catch
    {
        return
    }
}
