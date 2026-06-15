<#
.SYNOPSIS
    Lists all members of an Active Directory group with controlled recursion depth.

.DESCRIPTION
    Enhanced version of Get-sqmADGroupMembers with support for limiting nesting depth.
    Recursively resolves nested groups up to the specified depth level.

    Example: If GroupA contains GroupB (which contains User2):
    - Depth 0: GroupB only (direct members)
    - Depth 1: GroupB + User2 (one level of nesting)
    - Depth 2: GroupB + User2 + any groups within (two levels)

.PARAMETER GroupName
    Name of the AD group. Pipeline-capable.
    Format: "GroupName" or "DOMAIN\GroupName"

.PARAMETER Domain
    Optional: AD domain (e.g., "FITS.LOCAL", "corp.de")
    If not specified, auto-detects current domain.

.PARAMETER Depth
    Maximum nesting depth for group expansion (default: 2)
    - 0: Direct members only (no recursion)
    - 1: Expand nested groups one level
    - 2: Expand nested groups two levels (recommended)
    - 3+: Deeper nesting (may slow down large AD structures)

.PARAMETER OutputPath
    Optional: Output directory for TXT/CSV reports
    Default: C:\System\WinSrvLog\MSSQL

.OUTPUTS
    PSCustomObject with GroupName, MemberCount, Members[], Depth, TxtFile, CsvFile, Status

.EXAMPLE
    Get-sqmADGroupMembersRecursive -GroupName "DL_SQL_Admins" -Depth 2

.EXAMPLE
    Get-sqmADGroupMembersRecursive -GroupName "Administrators" -Domain "FITS" -Depth 1

.NOTES
    Author: sqmSQLTool
    Supports controlled recursive expansion of nested groups
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
        [string]$OutputPath = "C:\System\WinSrvLog\MSSQL"
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name
        $allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
        $processedGroups = @{}  # Track processed groups to avoid circular references

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
        foreach ($group in $GroupName)
        {
            $members = [System.Collections.Generic.List[PSCustomObject]]::new()
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

                $cleanGroup = $group -replace '^[^\\]*\\', ''
                Invoke-sqmLogging -Message "[$cleanGroup] Domain: $targetDomain, Depth: $Depth" -FunctionName $functionName -Level "VERBOSE"

                # Helper function for recursive expansion
                function Expand-ADGroupMembers
                {
                    param(
                        [string]$GroupIdentity,
                        [int]$CurrentDepth,
                        [int]$MaxDepth,
                        [hashtable]$Visited
                    )

                    # Prevent circular references
                    if ($Visited.ContainsKey($GroupIdentity.ToLower()))
                    {
                        return @()
                    }
                    $Visited[$GroupIdentity.ToLower()] = $true

                    $expandedMembers = @()

                    try
                    {
                        # Try Get-ADGroupMember first
                        if (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
                        {
                            $null = Import-Module ActiveDirectory -ErrorAction Stop
                            $adMembers = Get-ADGroupMember -Identity $GroupIdentity -ErrorAction Stop

                            foreach ($member in $adMembers)
                            {
                                $memberObj = [PSCustomObject]@{
                                    SamAccountName = $member.SamAccountName
                                    DisplayName    = $member.Name
                                    ObjectClass    = $member.objectClass
                                    Depth          = $CurrentDepth
                                    DN             = if ($member | Get-Member -Name DistinguishedName) { $member.DistinguishedName } else { $null }
                                }
                                $expandedMembers += $memberObj

                                # If it's a group and we haven't reached max depth, recurse
                                if ($member.objectClass -eq 'group' -and $CurrentDepth -lt $MaxDepth)
                                {
                                    $nestedMembers = Expand-ADGroupMembers -GroupIdentity $member.SamAccountName -CurrentDepth ($CurrentDepth + 1) -MaxDepth $MaxDepth -Visited $Visited
                                    $expandedMembers += $nestedMembers
                                }
                            }
                        }
                    }
                    catch
                    {
                        # Fallback to LDAP if AD module fails
                        try
                        {
                            $root = [ADSI]"LDAP://$targetDomain/RootDSE"
                            $searcher = [System.DirectoryServices.DirectorySearcher]::new()
                            $searcher.SearchRoot = [ADSI]("LDAP://" + $root.defaultNamingContext[0])
                            $searcher.Filter = "(&(|(sAMAccountName=$GroupIdentity)(distinguishedName=$GroupIdentity)))"
                            $result = $searcher.FindOne()

                            if ($result)
                            {
                                $memberDNs = @()
                                try
                                {
                                    $memberDNs = @($result.Properties['member'])
                                }
                                catch
                                {
                                    $memberDNs = @($result.GetDirectoryEntry().psbase.InvokeGet("member"))
                                }

                                foreach ($memberDN in $memberDNs)
                                {
                                    try
                                    {
                                        $memberEntry = [ADSI]"LDAP://$memberDN"
                                        $sam = $memberEntry.psbase.InvokeGet("sAMAccountName")
                                        $disp = $memberEntry.psbase.InvokeGet("displayName")
                                        $cls = $memberEntry.psbase.InvokeGet("objectClass")
                                        if ($cls -is [array]) { $cls = $cls[-1] }

                                        $memberObj = [PSCustomObject]@{
                                            SamAccountName = $sam
                                            DisplayName    = $disp
                                            ObjectClass    = $cls
                                            Depth          = $CurrentDepth
                                            DN             = $memberDN
                                        }
                                        $expandedMembers += $memberObj

                                        # If group and not at max depth, recurse
                                        if ($cls -eq 'group' -and $CurrentDepth -lt $MaxDepth)
                                        {
                                            $nestedMembers = Expand-ADGroupMembers -GroupIdentity $sam -CurrentDepth ($CurrentDepth + 1) -MaxDepth $MaxDepth -Visited $Visited
                                            $expandedMembers += $nestedMembers
                                        }
                                    }
                                    catch
                                    {
                                        # Skip members we can't process
                                    }
                                }
                            }
                        }
                        catch
                        {
                            # Last resort failed
                        }
                    }

                    return $expandedMembers
                }

                # Start recursive expansion
                $allMembers = Expand-ADGroupMembers -GroupIdentity $cleanGroup -CurrentDepth 0 -MaxDepth $Depth -Visited $processedGroups

                # Remove duplicates and sort
                $members = $allMembers | Sort-Object -Property SamAccountName -Unique

                # Write report files
                $txtFile = $null
                $csvFile = $null

                if ($PSCmdlet.ShouldProcess($cleanGroup, "Erstelle Bericht"))
                {
                    if (-not (Test-Path $OutputPath))
                    {
                        New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
                    }

                    $safeGroup = $cleanGroup -replace '[\\/:*?"<>|]', '_'
                    $txtFile = Join-Path $OutputPath "ADGroupMembers_${safeGroup}_Depth${Depth}_${datestamp}.txt"
                    $csvFile = Join-Path $OutputPath "ADGroupMembers_${safeGroup}_Depth${Depth}_${datestamp}.csv"

                    $lines = @(
                        "# sqmSQLTool - www.powershelldba.de"
                        "# ================================================================"
                        "# AD Group Members Report (Recursive)"
                        "# Gruppe    : $cleanGroup"
                        "# Domain    : $targetDomain"
                        "# Depth     : $Depth"
                        "# Erstellt  : $timestamp"
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

                    Invoke-sqmLogging -Message "[$cleanGroup] Bericht: $txtFile" -FunctionName $functionName -Level "INFO"
                }

                # Result object
                $allResults.Add([PSCustomObject]@{
                        GroupName   = $cleanGroup
                        Domain      = $targetDomain
                        Depth       = $Depth
                        MemberCount = $members.Count
                        Members     = $members
                        Timestamp   = $timestamp
                        TxtFile     = $txtFile
                        CsvFile     = $csvFile
                        Status      = if ($members.Count -gt 0) { 'OK' } else { 'Warning' }
                    })

                Invoke-sqmLogging -Message "[$cleanGroup] $($members.Count) Members mit Depth=$Depth expandiert" -FunctionName $functionName -Level "VERBOSE"
            }
            catch
            {
                $errMsg = "Fehler bei Gruppe '$group': $($_.Exception.Message)"
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
                        Status      = 'Error'
                        Message     = $errMsg
                    })
            }
        }
    }

    end
    {
        Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Gruppen verarbeitet." -FunctionName $functionName -Level "INFO"
        return $allResults
    }
}
