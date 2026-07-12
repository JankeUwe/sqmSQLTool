<#
.SYNOPSIS
    Lists all members of an Active Directory group with controlled recursion depth.

.DESCRIPTION
    Enhanced version of Get-sqmADGroupMembers with support for limiting nesting depth.
    Recursively resolves nested groups up to the specified depth level.

    For user accounts the real AD 'displayName' attribute is resolved (via Get-ADUser),
    so the DisplayName column shows the person's name instead of just the login/CN.
    Fallback chain: displayName -> CN/Name -> sAMAccountName.

.PARAMETER GroupName
    Name of the AD group. Pipeline-capable.

.PARAMETER Domain
    Optional: AD domain (e.g., "FITS.LOCAL", "corp.de")
    If not specified, auto-detects current domain.

.PARAMETER Depth
    Maximum nesting depth for group expansion (default: 2)

.PARAMETER OutputPath
    Optional: Output directory for TXT/CSV reports
    Default: C:\System\WinSrvLog\MSSQL

.OUTPUTS
    PSCustomObject with GroupName, MemberCount, Members[], Depth, TxtFile, CsvFile, Status

.EXAMPLE
    Get-sqmADGroupMembersRecursive -GroupName "DL_SQL_Admins" -Depth 2

.NOTES
    Author: sqmSQLTool
    Based on Get-sqmADGroupMembers with -Depth parameter
#>
function Get-sqmADGroupMembersRecursive
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
        [ValidateRange(0, 10)]
        [int]$Depth = 2,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath = "C:\System\WinSrvLog\MSSQL",

        [Parameter(Mandatory = $false)]
        [switch]$NoOpen
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name
        $allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
        $processedGroups = @{}

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
        foreach ($group in $GroupName)
        {
            $members = [System.Collections.Generic.List[PSCustomObject]]::new()
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

                $cleanGroup = $group -replace '^[^\\]*\\', ''
                Invoke-sqmLogging -Message "[$cleanGroup] Domain: $targetDomain, Depth: $Depth" -FunctionName $functionName -Level "VERBOSE"

                # Helper function for recursive expansion
                function Expand-GroupMembers
                {
                    param(
                        [string]$GroupIdentity,
                        [int]$CurrentDepth,
                        [int]$MaxDepth,
                        [hashtable]$Visited
                    )

                    if ($Visited.ContainsKey($GroupIdentity.ToLower()))
                    {
                        return @()
                    }
                    $Visited[$GroupIdentity.ToLower()] = $true

                    $expandedMembers = @()

                    try
                    {
                        if (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
                        {
                            $null = Import-Module ActiveDirectory -ErrorAction Stop

                            # CRITICAL: Use -Recursive to get nested members
                            if ($CurrentDepth -eq 0)
                            {
                                # First call: Get all with -Recursive built-in
                                $adMembers = Get-ADGroupMember -Identity $GroupIdentity -Recursive -ErrorAction Stop
                            }
                            else
                            {
                                # Nested calls: only direct members
                                $adMembers = Get-ADGroupMember -Identity $GroupIdentity -ErrorAction Stop
                            }

                            foreach ($member in $adMembers)
                            {
                                # Get-ADGroupMember liefert nur CN/Name (oft = Login), NICHT das
                                # AD-Attribut displayName. Fuer User den echten Anzeigenamen nachladen.
                                $disp = $member.Name
                                if ($member.objectClass -eq 'user')
                                {
                                    try
                                    {
                                        $adUser = Get-ADUser -Identity $member.SID -Properties DisplayName -ErrorAction Stop
                                        if ($adUser.DisplayName) { $disp = $adUser.DisplayName }
                                    }
                                    catch { }
                                }

                                $memberObj = [PSCustomObject]@{
                                    SamAccountName = $member.SamAccountName
                                    DisplayName    = $disp
                                    ObjectClass    = $member.objectClass
                                    Depth          = $CurrentDepth
                                }
                                $expandedMembers += $memberObj
                            }
                        }
                    }
                    catch
                    {
                        # Fallback to LDAP - use original method
                        try
                        {
                            $root = [ADSI]"LDAP://$targetDomain/RootDSE"
                            $searcher = [System.DirectoryServices.DirectorySearcher]::new()
                            $searcher.SearchRoot = [ADSI]("LDAP://" + $root.defaultNamingContext[0])
                            $searcher.Filter = "(sAMAccountName=$GroupIdentity)"
                            $groupResult = $searcher.FindOne()

                            if ($groupResult)
                            {
                                $groupDN = $groupResult.Properties['distinguishedName'][0]
                                $groupEntry = [ADSI]"LDAP://$groupDN"

                                $memberDNs = @()
                                try
                                {
                                    $memberDNs = @($groupEntry.psbase.InvokeGet("member"))
                                }
                                catch
                                {
                                    $memberDNs = @($groupEntry.psbase.Properties['member'])
                                }

                                foreach ($memberDN in $memberDNs)
                                {
                                    try
                                    {
                                        $memberEntry = [ADSI]"LDAP://$memberDN"
                                        $sam = $memberEntry.psbase.InvokeGet("sAMAccountName")
                                        # displayName tolerant lesen: fehlt das Attribut, wirft InvokeGet
                                        # sonst eine Exception und der Member ginge verloren.
                                        # Fallback-Kette: displayName -> cn -> sAMAccountName.
                                        $disp = $null
                                        try { $disp = $memberEntry.psbase.InvokeGet("displayName") } catch { }
                                        if (-not $disp) { try { $disp = $memberEntry.psbase.InvokeGet("cn") } catch { } }
                                        if (-not $disp) { $disp = $sam }
                                        $cls = $memberEntry.psbase.InvokeGet("objectClass")
                                        if ($cls -is [array]) { $cls = $cls[-1] }

                                        $memberObj = [PSCustomObject]@{
                                            SamAccountName = $sam
                                            DisplayName    = $disp
                                            ObjectClass    = $cls
                                            Depth          = $CurrentDepth
                                        }
                                        $expandedMembers += $memberObj

                                        # Recurse if group and not at max depth
                                        if ($cls -eq 'group' -and $CurrentDepth -lt $MaxDepth)
                                        {
                                            $nested = Expand-GroupMembers -GroupIdentity $sam -CurrentDepth ($CurrentDepth + 1) -MaxDepth $MaxDepth -Visited $Visited
                                            $expandedMembers += $nested
                                        }
                                    }
                                    catch { }
                                }
                            }
                        }
                        catch { }
                    }

                    return $expandedMembers
                }

                # Start expansion
                $allMembers = Expand-GroupMembers -GroupIdentity $cleanGroup -CurrentDepth 0 -MaxDepth $Depth -Visited $processedGroups
                $members = $allMembers | Sort-Object -Property SamAccountName -Unique

                # Write reports
                $txtFile = $null
                $csvFile = $null
                $htmlFile = $null

                if ($PSCmdlet.ShouldProcess($cleanGroup, "Create report"))
                {
                    if (-not (Test-Path $OutputPath))
                    {
                        New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
                    }

                    $safeGroup = $cleanGroup -replace '[\\/:*?"<>|]', '_'
                    $txtFile = Join-Path $OutputPath "ADGroupMembers_${safeGroup}_Depth${Depth}_${datestamp}.txt"
                    $csvFile = Join-Path $OutputPath "ADGroupMembers_${safeGroup}_Depth${Depth}_${datestamp}.csv"
                    $htmlFile = Join-Path $OutputPath "ADGroupMembers_${safeGroup}_Depth${Depth}_${datestamp}.html"

                    $lines = @(
                        "# sqmSQLTool - www.powershelldba.de"
                        "# ================================================================"
                        "# AD Group Members Report (Recursive with Depth Control)"
                        "# Group     : $cleanGroup"
                        "# Domain    : $targetDomain"
                        "# Depth     : $Depth"
                        "# Created   : $timestamp"
                        "# Members   : $($members.Count)"
                        "# ================================================================"
                        ""
                        ("{0,-30} {1,-35} {2,-12} {3}" -f 'SamAccountName', 'DisplayName', 'Type', 'Level')
                        ("-" * 95)
                    )

                    foreach ($member in $members)
                    {
                        $lines += ("{0,-30} {1,-35} {2,-12} {3}" -f $member.SamAccountName, $member.DisplayName, $member.ObjectClass, $member.Depth)
                    }

                    $lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
                    $members | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

                    # HTML report
                    $rowsHtml = foreach ($m in $members)
                    {
                        "<tr><td>$([System.Net.WebUtility]::HtmlEncode($m.SamAccountName))</td><td>$([System.Net.WebUtility]::HtmlEncode($m.DisplayName))</td><td>$($m.ObjectClass)</td><td>$($m.Depth)</td></tr>"
                    }
                    $bodyHtml = "<p>Gruppe: $([System.Net.WebUtility]::HtmlEncode($cleanGroup)) | Domain: $([System.Net.WebUtility]::HtmlEncode($targetDomain)) | Depth: $Depth | Mitglieder: $($members.Count)</p>" +
                        "<table><tr><th>SamAccountName</th><th>DisplayName</th><th>Type</th><th>Level</th></tr>" +
                        ($rowsHtml -join '') + "</table>"
                    $html = ConvertTo-sqmHtmlReport -Title "AD Group Members (Recursive) - $cleanGroup" -Subtitle "Erstellt: $timestamp | Depth: $Depth" -BodyHtml $bodyHtml
                    $html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

                    Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen

                    Invoke-sqmLogging -Message "[$cleanGroup] Report: $htmlFile" -FunctionName $functionName -Level "INFO"
                }

                $allResults.Add([PSCustomObject]@{
                        GroupName   = $cleanGroup
                        Domain      = $targetDomain
                        Depth       = $Depth
                        MemberCount = $members.Count
                        Members     = $members
                        Timestamp   = $timestamp
                        TxtFile     = $txtFile
                        CsvFile     = $csvFile
                        HtmlFile    = $htmlFile
                        Status      = if ($members.Count -gt 0) { 'OK' } else { 'Warning' }
                    })

                Invoke-sqmLogging -Message "[$cleanGroup] $($members.Count) Members found with Depth=$Depth" -FunctionName $functionName -Level "VERBOSE"
            }
            catch
            {
                $errMsg = "Error processing group '$group': $($_.Exception.Message)"
                Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
                $allResults.Add([PSCustomObject]@{
                        GroupName   = $group
                        Domain      = $Domain
                        Depth       = $Depth
                        MemberCount = 0
                        Members     = $null
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
        Invoke-sqmLogging -Message "$functionName completed. $($allResults.Count) groups processed." -FunctionName $functionName -Level "INFO"
        return $allResults
    }
}
