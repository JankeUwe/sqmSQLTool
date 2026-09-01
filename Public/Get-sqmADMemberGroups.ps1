<#
.SYNOPSIS
    Finds all Active Directory groups that contain a specified user, group, or computer.

.DESCRIPTION
    Inverse operation to Get-sqmADGroupMembers.
    Lists all groups (direct and nested) that contain the specified member.

    The real AD 'displayName' attribute of the queried Identity itself is also resolved (via
    Get-ADObject or LDAP), so the report shows the person's actual name next to the
    SamAccountName/UPN that was passed in. Fallback chain: displayName -> CN/Name -> the
    identity as given.

.PARAMETER Identity
    Identity of the user, group, or computer.
    Can be: SamAccountName, UPN, or DistinguishedName
    Pipeline-capable.

.PARAMETER Domain
    Optional: AD domain

.PARAMETER Depth
    Maximum nesting depth for group expansion (default: 2)

.PARAMETER OutputPath
    Optional: Output directory for TXT/CSV reports
    Default: C:\System\WinSrvLog\MSSQL

.OUTPUTS
    PSCustomObject with Identity, DisplayName, GroupCount, Groups[], Depth, TxtFile, CsvFile, Status

.EXAMPLE
    Get-sqmADMemberGroups -Identity "john.doe" -Depth 2

.NOTES
    Author: sqmSQLTool
    Inverse of Get-sqmADGroupMembers
#>
function Get-sqmADMemberGroups
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Identity,

        [Parameter(Mandatory = $false)]
        [string]$Domain,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 10)]
        [int]$Depth = 2,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'ADMemberGroups'),

        [Parameter(Mandatory = $false)]
        [switch]$NoOpen
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name
        $allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

        try
        {
            $null = [ADSI]"LDAP://RootDSE"
            Invoke-sqmLogging -Message "ADSI connection successful." -FunctionName $functionName -Level "INFO"
        }
        catch
        {
            $errMsg = "ADSI connection failed - no Domain Controller reachable."
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
            throw $errMsg
        }

        Invoke-sqmLogging -Message "Starting $functionName with Depth=$Depth" -FunctionName $functionName -Level "INFO"
    }

    process
    {
        foreach ($member in $Identity)
        {
            $parentGroups = [System.Collections.Generic.List[PSCustomObject]]::new()
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $datestamp = Get-Date -Format 'yyyy-MM-dd'

            try
            {
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

                $cleanIdentity = $member -replace '^[^\\]*\\', ''
                Invoke-sqmLogging -Message "[$cleanIdentity] Domain: $targetDomain, Depth: $Depth" -FunctionName $functionName -Level "VERBOSE"

                # Resolve the real (display) name of the QUERIED account itself. Find-ParentGroups
                # below already resolves DisplayName for the GROUPS it finds, but never for the
                # identity being looked up - the report only ever showed the raw SamAccountName.
                # Identity can be a user, group or computer (see .PARAMETER), so this uses a
                # class-agnostic LDAPFilter/InvokeGet lookup rather than Get-ADUser, which would
                # throw for a group or computer identity.
                $identityDisplayName = $cleanIdentity
                try
                {
                    if (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
                    {
                        $null = Import-Module ActiveDirectory -ErrorAction Stop
                        $adSelf = Get-ADObject -LDAPFilter "(|(sAMAccountName=$cleanIdentity)(userPrincipalName=$cleanIdentity))" -Properties DisplayName, Name -ErrorAction Stop |
                        Select-Object -First 1
                        if ($adSelf)
                        {
                            if ($adSelf.DisplayName) { $identityDisplayName = $adSelf.DisplayName }
                            elseif ($adSelf.Name) { $identityDisplayName = $adSelf.Name }
                        }
                    }
                }
                catch
                {
                    Invoke-sqmLogging -Message "[$cleanIdentity] AD-Modul-Namensaufloesung fehlgeschlagen: $_" -FunctionName $functionName -Level "VERBOSE"
                }
                if ($identityDisplayName -eq $cleanIdentity)
                {
                    # LDAP fallback - module missing or the lookup above didn't resolve a name.
                    try
                    {
                        $selfRoot = [ADSI]"LDAP://$targetDomain/RootDSE"
                        $selfSearcher = [System.DirectoryServices.DirectorySearcher]::new()
                        $selfSearcher.SearchRoot = [ADSI]("LDAP://" + $selfRoot.defaultNamingContext[0])
                        $selfSearcher.Filter = "(&(|(sAMAccountName=$cleanIdentity)(userPrincipalName=$cleanIdentity)))"
                        $selfResult = $selfSearcher.FindOne()
                        if ($selfResult)
                        {
                            $selfEntry = $selfResult.GetDirectoryEntry()
                            $selfDisp = $null
                            try { $selfDisp = $selfEntry.psbase.InvokeGet("displayName") } catch { }
                            if (-not $selfDisp) { try { $selfDisp = $selfEntry.psbase.InvokeGet("cn") } catch { } }
                            if ($selfDisp) { $identityDisplayName = $selfDisp }
                        }
                    }
                    catch
                    {
                        Invoke-sqmLogging -Message "[$cleanIdentity] LDAP-Namensaufloesung fehlgeschlagen: $_" -FunctionName $functionName -Level "VERBOSE"
                    }
                }

                # Helper function for recursive group lookup
                function Find-ParentGroups
                {
                    param(
                        [string]$MemberIdentity,
                        [int]$CurrentDepth,
                        [int]$MaxDepth,
                        [hashtable]$Visited
                    )

                    if ($Visited.ContainsKey($MemberIdentity.ToLower()))
                    {
                        return @()
                    }
                    $Visited[$MemberIdentity.ToLower()] = $true

                    $foundGroups = @()
                    $usedAdModule = $false

                    try
                    {
                        if (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
                        {
                            $null = Import-Module ActiveDirectory -ErrorAction Stop

                            # Get immediate parent groups
                            $memberGroups = Get-ADPrincipalGroupMembership -Identity $MemberIdentity -ErrorAction Stop
                            $usedAdModule = $true

                            foreach ($group in $memberGroups)
                            {
                                # Skip Domain Users - it's everyone
                                if ($group.Name -eq 'Domain Users')
                                {
                                    continue
                                }

                                $groupObj = [PSCustomObject]@{
                                    SamAccountName = $group.SamAccountName
                                    DisplayName    = $group.Name
                                    GroupScope     = if ($group | Get-Member -Name GroupScope) { $group.GroupScope } else { 'Unknown' }
                                    Depth          = $CurrentDepth
                                }
                                $foundGroups += $groupObj

                                # Recurse if not at max depth
                                if ($CurrentDepth -lt $MaxDepth)
                                {
                                    $parentOfParent = Find-ParentGroups -MemberIdentity $group.SamAccountName -CurrentDepth ($CurrentDepth + 1) -MaxDepth $MaxDepth -Visited $Visited
                                    $foundGroups += $parentOfParent
                                }
                            }
                        }
                    }
                    catch
                    {
                        # KORREKTUR: dieser catch fängt nur echte Fehler des AD-Modul-Pfads ab.
                        # Fehlt das ActiveDirectory-Modul einfach (if-Bedingung oben false), wirft
                        # das NIE eine Exception - ohne dieses Logging und $usedAdModule=false
                        # lief der LDAP-Fallback bisher nie an, wenn RSAT schlicht nicht installiert war.
                        Invoke-sqmLogging -Message "[$MemberIdentity] AD-Modul-Pfad fehlgeschlagen: $_" -FunctionName $functionName -Level "WARNING"
                        $usedAdModule = $false
                    }

                    if (-not $usedAdModule)
                    {
                        # LDAP fallback - greift jetzt sowohl bei fehlendem Modul als auch bei Fehlern darin
                        try
                        {
                            $root = [ADSI]"LDAP://$targetDomain/RootDSE"
                            $searcher = [System.DirectoryServices.DirectorySearcher]::new()
                            $searcher.SearchRoot = [ADSI]("LDAP://" + $root.defaultNamingContext[0])
                            $searcher.Filter = "(&(|(sAMAccountName=$MemberIdentity)(userPrincipalName=$MemberIdentity)))"
                            $result = $searcher.FindOne()

                            if ($result)
                            {
                                # KORREKTUR: vorher wurde der DN des Members roh in einen Gruppen-
                                # Suchfilter eingesetzt ("(member=$memberDN)") - bricht lautlos (0
                                # Treffer, keine Exception), sobald der DN Zeichen enthaelt, die im
                                # Filter anders escaped werden muessen als im DN selbst (z.B. Kommas
                                # bei CN="Nachname, Vorname" - hier Standard-Namenskonvention).
                                # Stattdessen: memberOf-Attribut direkt vom gefundenen User-Objekt
                                # lesen - derselbe Rueckverweis-Mechanismus wie
                                # Get-ADPrincipalGroupMembership, kein DN-in-Filter noetig.
                                $memberEntry = $result.GetDirectoryEntry()
                                $groupDNs = @()
                                try
                                {
                                    $groupDNs = @($memberEntry.psbase.InvokeGet("memberOf"))
                                }
                                catch { }

                                foreach ($groupDN in $groupDNs)
                                {
                                    try
                                    {
                                        $groupEntry = [ADSI]"LDAP://$groupDN"

                                        # KORREKTUR: jedes Attribut einzeln tolerant lesen. Vorher
                                        # riss ein einzelnes fehlendes/ungueltiges Attribut
                                        # (z.B. "groupScope" - kein echtes LDAP-Attribut, existiert
                                        # nur als berechnete Eigenschaft im AD-PowerShell-Modul; das
                                        # Schema kennt nur "groupType") den kompletten Gruppen-
                                        # Datensatz per Exception aus der Ergebnisliste.
                                        $sam = $null
                                        try { $sam = $groupEntry.psbase.InvokeGet("sAMAccountName") } catch { }
                                        if (-not $sam) { continue }

                                        $disp = $null
                                        try { $disp = $groupEntry.psbase.InvokeGet("displayName") } catch { }
                                        if (-not $disp) { try { $disp = $groupEntry.psbase.InvokeGet("cn") } catch { } }
                                        if (-not $disp) { $disp = $sam }

                                        $scope = $null
                                        try { $scope = $groupEntry.psbase.InvokeGet("groupType") } catch { }

                                        if ($sam -ne 'Domain Users')
                                        {
                                            $groupObj = [PSCustomObject]@{
                                                SamAccountName = $sam
                                                DisplayName    = $disp
                                                GroupScope     = $scope
                                                Depth          = $CurrentDepth
                                            }
                                            $foundGroups += $groupObj

                                            # Recurse if not at max depth
                                            if ($CurrentDepth -lt $MaxDepth)
                                            {
                                                $parentOfParent = Find-ParentGroups -MemberIdentity $sam -CurrentDepth ($CurrentDepth + 1) -MaxDepth $MaxDepth -Visited $Visited
                                                $foundGroups += $parentOfParent
                                            }
                                        }
                                    }
                                    catch { }
                                }
                            }
                        }
                        catch
                        {
                            Invoke-sqmLogging -Message "[$MemberIdentity] LDAP-Fallback fehlgeschlagen: $_" -FunctionName $functionName -Level "WARNING"
                        }
                    }

                    return $foundGroups
                }

                # Start lookup
                $allGroups = Find-ParentGroups -MemberIdentity $cleanIdentity -CurrentDepth 0 -MaxDepth $Depth -Visited @{}
                $parentGroups = $allGroups | Sort-Object -Property SamAccountName -Unique

                # Write reports
                $txtFile = $null
                $csvFile = $null
                $htmlFile = $null

                if ($PSCmdlet.ShouldProcess($cleanIdentity, "Create report"))
                {
                    if (-not (Test-Path $OutputPath))
                    {
                        New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
                    }

                    $safeIdentity = $cleanIdentity -replace '[\\/:*?"<>|]', '_'
                    $txtFile = Join-Path $OutputPath "ADMemberGroups_${safeIdentity}_Depth${Depth}_${datestamp}.txt"
                    $csvFile = Join-Path $OutputPath "ADMemberGroups_${safeIdentity}_Depth${Depth}_${datestamp}.csv"
                    $htmlFile = Join-Path $OutputPath "ADMemberGroups_${safeIdentity}_Depth${Depth}_${datestamp}.html"

                    $lines = @(
                        "# sqmSQLTool - www.powershelldba.de"
                        "# ================================================================"
                        "# AD Member Groups Report"
                        "# Member    : $cleanIdentity"
                        "# Real Name : $identityDisplayName"
                        "# Domain    : $targetDomain"
                        "# Depth     : $Depth"
                        "# Created   : $timestamp"
                        "# Groups    : $($parentGroups.Count)"
                        "# ================================================================"
                        ""
                        ("{0,-30} {1,-35} {2,-12} {3}" -f 'GroupName', 'DisplayName', 'Scope', 'Level')
                        ("-" * 95)
                    )

                    foreach ($group in $parentGroups)
                    {
                        $lines += ("{0,-30} {1,-35} {2,-12} {3}" -f $group.SamAccountName, $group.DisplayName, $group.GroupScope, $group.Depth)
                    }

                    $lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
                    $parentGroups | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

                    # HTML report
                    $rowsHtml = foreach ($g in $parentGroups)
                    {
                        "<tr><td>$([System.Net.WebUtility]::HtmlEncode($g.SamAccountName))</td><td>$([System.Net.WebUtility]::HtmlEncode($g.DisplayName))</td><td>$($g.GroupScope)</td><td>$($g.Depth)</td></tr>"
                    }
                    $bodyHtml = "<p>Mitglied: $([System.Net.WebUtility]::HtmlEncode($cleanIdentity)) ($([System.Net.WebUtility]::HtmlEncode($identityDisplayName))) | Domain: $([System.Net.WebUtility]::HtmlEncode($targetDomain)) | Depth: $Depth | Gruppen: $($parentGroups.Count)</p>" +
                        "<table><tr><th>GroupName</th><th>DisplayName</th><th>Scope</th><th>Level</th></tr>" +
                        ($rowsHtml -join '') + "</table>"
                    $html = ConvertTo-sqmHtmlReport -Title "AD Member Groups - $cleanIdentity" -Subtitle "Erstellt: $timestamp | Depth: $Depth" -BodyHtml $bodyHtml
                    $html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

                    Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen

                    Invoke-sqmLogging -Message "[$cleanIdentity] Report: $htmlFile" -FunctionName $functionName -Level "INFO"
                }

                $allResults.Add([PSCustomObject]@{
                        Identity    = $cleanIdentity
                        DisplayName = $identityDisplayName
                        Domain      = $targetDomain
                        Depth       = $Depth
                        GroupCount  = $parentGroups.Count
                        Groups      = $parentGroups
                        Timestamp   = $timestamp
                        TxtFile     = $txtFile
                        CsvFile     = $csvFile
                        HtmlFile    = $htmlFile
                        Status      = if ($parentGroups.Count -gt 0) { 'OK' } else { 'NoGroups' }
                    })

                Invoke-sqmLogging -Message "[$cleanIdentity] $($parentGroups.Count) Groups found with Depth=$Depth" -FunctionName $functionName -Level "VERBOSE"
            }
            catch
            {
                $errMsg = "Error processing member '$member': $($_.Exception.Message)"
                Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
                $allResults.Add([PSCustomObject]@{
                        Identity    = $member
                        DisplayName = $null
                        Domain      = $Domain
                        Depth       = $Depth
                        GroupCount  = 0
                        Groups      = $null
                        Timestamp   = $timestamp
                        TxtFile     = $null
                        CsvFile     = $null
                        HtmlFile    = $null
                        Status      = 'Error'
                        Message     = $errMsg
                    })
            }
        }
    }

    end
    {
        Invoke-sqmLogging -Message "$functionName completed. $($allResults.Count) members processed." -FunctionName $functionName -Level "INFO"
        return $allResults
    }
}
