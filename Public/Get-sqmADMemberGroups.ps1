<#
.SYNOPSIS
    Finds all Active Directory groups that contain a specified user, group, or computer.

.DESCRIPTION
    Inverse operation to Get-sqmADGroupMembers.
    Lists all groups (direct and nested) that contain the specified member.

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
    PSCustomObject with Identity, GroupName, GroupCount, Groups[], Depth, TxtFile, CsvFile, Status

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
        [string]$OutputPath = "C:\System\WinSrvLog\MSSQL",

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

                    try
                    {
                        if (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
                        {
                            $null = Import-Module ActiveDirectory -ErrorAction Stop

                            # Get immediate parent groups
                            $memberGroups = Get-ADPrincipalGroupMembership -Identity $MemberIdentity -ErrorAction Stop

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
                        # LDAP fallback if AD module fails
                        try
                        {
                            $root = [ADSI]"LDAP://$targetDomain/RootDSE"
                            $searcher = [System.DirectoryServices.DirectorySearcher]::new()
                            $searcher.SearchRoot = [ADSI]("LDAP://" + $root.defaultNamingContext[0])
                            $searcher.Filter = "(&(|(sAMAccountName=$MemberIdentity)(userPrincipalName=$MemberIdentity)))"
                            $result = $searcher.FindOne()

                            if ($result)
                            {
                                $memberDN = $result.Properties['distinguishedName'][0]

                                # Query for groups containing this member
                                $groupSearcher = [System.DirectoryServices.DirectorySearcher]::new()
                                $groupSearcher.SearchRoot = [ADSI]("LDAP://" + $root.defaultNamingContext[0])
                                $groupSearcher.Filter = "(&(objectClass=group)(member=$memberDN))"
                                $groupResults = $groupSearcher.FindAll()

                                foreach ($groupResult in $groupResults)
                                {
                                    try
                                    {
                                        $groupEntry = $groupResult.GetDirectoryEntry()
                                        $sam = $groupEntry.psbase.InvokeGet("sAMAccountName")
                                        $disp = $groupEntry.psbase.InvokeGet("displayName")
                                        $scope = $groupEntry.psbase.InvokeGet("groupScope")

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
                        catch { }
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
                    $bodyHtml = "<p>Mitglied: $([System.Net.WebUtility]::HtmlEncode($cleanIdentity)) | Domain: $([System.Net.WebUtility]::HtmlEncode($targetDomain)) | Depth: $Depth | Gruppen: $($parentGroups.Count)</p>" +
                        "<table><tr><th>GroupName</th><th>DisplayName</th><th>Scope</th><th>Level</th></tr>" +
                        ($rowsHtml -join '') + "</table>"
                    $html = ConvertTo-sqmHtmlReport -Title "AD Member Groups - $cleanIdentity" -Subtitle "Erstellt: $timestamp | Depth: $Depth" -BodyHtml $bodyHtml
                    $html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

                    Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen

                    Invoke-sqmLogging -Message "[$cleanIdentity] Report: $htmlFile" -FunctionName $functionName -Level "INFO"
                }

                $allResults.Add([PSCustomObject]@{
                        Identity    = $cleanIdentity
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
