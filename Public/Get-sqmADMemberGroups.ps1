<#
.SYNOPSIS
    Finds all Active Directory groups that contain a specified user, group, or computer.

.DESCRIPTION
    Inverse operation to Get-sqmADGroupMembers.
    Lists all groups (direct and nested) that contain the specified member.

    Useful for:
    - Security audits: "Which groups is this user in?"
    - Troubleshooting permissions: "Why does this user have these rights?"
    - Access verification: "Confirm user group membership"

    Example: If User is in GroupA, and GroupA is in GroupB:
    - Depth 0: GroupA only (direct groups)
    - Depth 1: GroupA + GroupB (one level up)
    - Depth 2: GroupA + GroupB + any parent groups

.PARAMETER Identity
    Identity of the user, group, or computer to find parent groups for.
    Can be: SamAccountName, UPN, or DistinguishedName
    Pipeline-capable.

.PARAMETER Domain
    Optional: AD domain (e.g., "FITS.LOCAL", "corp.de")
    If not specified, auto-detects current domain.

.PARAMETER Depth
    Maximum nesting depth for group expansion (default: 2)
    - 0: Direct groups only (immediate parent groups)
    - 1: Direct groups + their parent groups (one level up)
    - 2: Two levels up (recommended)
    - 3+: Deeper nesting

.PARAMETER OutputPath
    Optional: Output directory for TXT/CSV reports
    Default: C:\System\WinSrvLog\MSSQL

.OUTPUTS
    PSCustomObject with Identity, GroupName, GroupCount, Groups[], Depth, TxtFile, CsvFile, Status

.EXAMPLE
    Get-sqmADMemberGroups -Identity "john.doe" -Depth 2

.EXAMPLE
    Get-sqmADMemberGroups -Identity "contoso\Domain Users" -Domain "FITS"

.EXAMPLE
    "user1", "user2" | Get-sqmADMemberGroups -Depth 1

.NOTES
    Author: sqmSQLTool
    Complements Get-sqmADGroupMembers for bidirectional AD group analysis
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
        [string]$OutputPath = "C:\System\WinSrvLog\MSSQL"
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name
        $allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
        $processedMembers = @{}  # Track to avoid circular references

        # Test ADSI connectivity
        try
        {
            $null = [ADSI]"LDAP://RootDSE"
            Invoke-sqmLogging -Message "ADSI-Verbindung erfolgreich." -FunctionName $functionName -Level "INFO"
        }
        catch
        {
            $errMsg = "ADSI-Verbindung fehlgeschlagen - kein Domain Controller erreichbar."
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
            throw $errMsg
        }

        Invoke-sqmLogging -Message "Starte $functionName mit Depth=$Depth" -FunctionName $functionName -Level "INFO"
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
                # Determine domain
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

                # Helper function for recursive parent group lookup
                function Find-ParentGroups
                {
                    param(
                        [string]$MemberIdentity,
                        [int]$CurrentDepth,
                        [int]$MaxDepth,
                        [string]$TargetDomain,
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
                        # Try Get-ADPrincipalGroupMembership if available
                        if (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
                        {
                            $null = Import-Module ActiveDirectory -ErrorAction Stop
                            $memberGroups = Get-ADPrincipalGroupMembership -Identity $MemberIdentity -ErrorAction Stop

                            foreach ($group in $memberGroups)
                            {
                                $groupObj = [PSCustomObject]@{
                                    SamAccountName = $group.SamAccountName
                                    DisplayName    = $group.Name
                                    GroupScope     = if ($group | Get-Member -Name GroupScope) { $group.GroupScope } else { 'Unknown' }
                                    Depth          = $CurrentDepth
                                    DN             = if ($group | Get-Member -Name DistinguishedName) { $group.DistinguishedName } else { $null }
                                }
                                $foundGroups += $groupObj

                                # If not at max depth, find parent groups of this group
                                if ($CurrentDepth -lt $MaxDepth)
                                {
                                    $parentOfParent = Find-ParentGroups -MemberIdentity $group.SamAccountName -CurrentDepth ($CurrentDepth + 1) -MaxDepth $MaxDepth -TargetDomain $TargetDomain -Visited $Visited
                                    $foundGroups += $parentOfParent
                                }
                            }
                        }
                    }
                    catch
                    {
                        # Fallback to LDAP
                        try
                        {
                            $root = [ADSI]"LDAP://$TargetDomain/RootDSE"
                            $searcher = [System.DirectoryServices.DirectorySearcher]::new()
                            $searcher.SearchRoot = [ADSI]("LDAP://" + $root.defaultNamingContext[0])
                            $searcher.Filter = "(&(|(sAMAccountName=$MemberIdentity)(distinguishedName=$MemberIdentity)))"
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

                                        $groupObj = [PSCustomObject]@{
                                            SamAccountName = $sam
                                            DisplayName    = $disp
                                            GroupScope     = $scope
                                            Depth          = $CurrentDepth
                                            DN             = $groupResult.Properties['distinguishedName'][0]
                                        }
                                        $foundGroups += $groupObj

                                        # Recurse if not at max depth
                                        if ($CurrentDepth -lt $MaxDepth)
                                        {
                                            $parentOfParent = Find-ParentGroups -MemberIdentity $sam -CurrentDepth ($CurrentDepth + 1) -MaxDepth $MaxDepth -TargetDomain $TargetDomain -Visited $Visited
                                            $foundGroups += $parentOfParent
                                        }
                                    }
                                    catch
                                    {
                                        # Skip groups we can't process
                                    }
                                }
                            }
                        }
                        catch
                        {
                            # Last resort failed
                        }
                    }

                    return $foundGroups
                }

                # Start recursive parent group lookup
                $allGroups = Find-ParentGroups -MemberIdentity $cleanIdentity -CurrentDepth 0 -MaxDepth $Depth -TargetDomain $targetDomain -Visited $processedMembers

                # Remove duplicates and sort
                $parentGroups = $allGroups | Sort-Object -Property SamAccountName -Unique

                # Write report files
                $txtFile = $null
                $csvFile = $null

                if ($PSCmdlet.ShouldProcess($cleanIdentity, "Erstelle Bericht"))
                {
                    if (-not (Test-Path $OutputPath))
                    {
                        New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
                    }

                    $safeIdentity = $cleanIdentity -replace '[\\/:*?"<>|]', '_'
                    $txtFile = Join-Path $OutputPath "ADMemberGroups_${safeIdentity}_Depth${Depth}_${datestamp}.txt"
                    $csvFile = Join-Path $OutputPath "ADMemberGroups_${safeIdentity}_Depth${Depth}_${datestamp}.csv"

                    $lines = @(
                        "# sqmSQLTool - www.powershelldba.de"
                        "# ================================================================"
                        "# AD Member Groups Report"
                        "# Member    : $cleanIdentity"
                        "# Domain    : $targetDomain"
                        "# Depth     : $Depth"
                        "# Erstellt  : $timestamp"
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

                    Invoke-sqmLogging -Message "[$cleanIdentity] Bericht: $txtFile" -FunctionName $functionName -Level "INFO"
                }

                # Result object
                $allResults.Add([PSCustomObject]@{
                        Identity    = $cleanIdentity
                        Domain      = $targetDomain
                        Depth       = $Depth
                        GroupCount  = $parentGroups.Count
                        Groups      = $parentGroups
                        Timestamp   = $timestamp
                        TxtFile     = $txtFile
                        CsvFile     = $csvFile
                        Status      = if ($parentGroups.Count -gt 0) { 'OK' } else { 'NoGroups' }
                    })

                Invoke-sqmLogging -Message "[$cleanIdentity] $($parentGroups.Count) Gruppen mit Depth=$Depth gefunden" -FunctionName $functionName -Level "VERBOSE"
            }
            catch
            {
                $errMsg = "Fehler bei Member '$member': $($_.Exception.Message)"
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
                        Status      = 'Error'
                        Message     = $errMsg
                    })
            }
        }
    }

    end
    {
        Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Members verarbeitet." -FunctionName $functionName -Level "INFO"
        return $allResults
    }
}
