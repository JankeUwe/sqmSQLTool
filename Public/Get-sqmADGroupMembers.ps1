<#
.SYNOPSIS
    Lists all members of an Active Directory group.

.DESCRIPTION
    Simple, reliable function to list members of an AD group (including nested groups).
    Useful when SQL Server access fails and you need to check group permissions.

    Supports NESTED GROUPS: Recursively resolves all members, including members of nested groups.
    Example: If GroupA contains GroupB (which contains User2), both GroupB and User2 are returned.

    Methods:
    1. Get-ADGroupMember -Recursive (if ActiveDirectory module available) — Resolves nested groups
    2. LDAP direct query (fallback, no module required) — Direct members only

.PARAMETER GroupName
    Name of the AD group. Pipeline-capable.
    Format: "GroupName" or "DOMAIN\GroupName"

.PARAMETER Domain
    Optional: AD domain (e.g., "FITS.LOCAL", "corp.de")
    If not specified, auto-detects current domain.

.OUTPUTS
    PSCustomObject with GroupName, MemberCount, Members[], TxtFile, CsvFile, Status

.EXAMPLE
    Get-sqmADGroupMembers -GroupName "DL_SQL_Admins"

.EXAMPLE
    Get-sqmADGroupMembers -GroupName "Administrators" -Domain "FITS"

.NOTES
    Author: sqmSQLTool
    Simple, reliable AD group member listing for diagnostics
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
        [string]$OutputPath = "C:\System\WinSrvLog\MSSQL",

        [Parameter(Mandatory = $false)]
        [switch]$NoOpen
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name
        $allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

        # Test ADSI connectivity
        try
        {
            $null = [ADSI]"LDAP://RootDSE"
            Invoke-sqmLogging -Message "ADSI-Verbindung erfolgreich." -FunctionName $functionName -Level "INFO"
        }
        catch
        {
            $errMsg = "ADSI-Verbindung fehlgeschlagen  - kein Domain Controller erreichbar."
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
            throw $errMsg
        }

        Invoke-sqmLogging -Message "Starte $functionName" -FunctionName $functionName -Level "INFO"
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
                Invoke-sqmLogging -Message "[$cleanGroup] Domain: $targetDomain" -FunctionName $functionName -Level "VERBOSE"

                # Method 1: Try Get-ADGroupMember (if AD module available)
                $methodUsed = "NONE"
                try
                {
                    if (Get-Module -ListAvailable -Name ActiveDirectory)
                    {
                        Import-Module ActiveDirectory -ErrorAction Stop
                        $adMembers = Get-ADGroupMember -Identity $cleanGroup -Recursive -ErrorAction Stop
                        foreach ($member in $adMembers)
                        {
                            $members.Add([PSCustomObject]@{
                                    SamAccountName = $member.SamAccountName
                                    DisplayName    = $member.Name
                                    ObjectClass    = $member.objectClass
                                })
                        }
                        $methodUsed = "Get-ADGroupMember"
                        Invoke-sqmLogging -Message "[$cleanGroup] $($members.Count) Members via Get-ADGroupMember" -FunctionName $functionName -Level "VERBOSE"
                    }
                }
                catch
                {
                    Invoke-sqmLogging -Message "[$cleanGroup] Get-ADGroupMember fehlgeschlagen, versuche LDAP..." -FunctionName $functionName -Level "VERBOSE"
                }

                # Method 2: LDAP direct query (fallback)
                if ($methodUsed -eq "NONE")
                {
                    try
                    {
                        # Get group object
                        $root = [ADSI]"LDAP://$targetDomain/RootDSE"
                        $searcher = [System.DirectoryServices.DirectorySearcher]::new()
                        $searcher.SearchRoot = [ADSI]("LDAP://" + $root.defaultNamingContext[0])
                        $searcher.Filter = "(sAMAccountName=$cleanGroup)"
                        $groupResult = $searcher.FindOne()

                        if ($groupResult)
                        {
                            $groupDN = $groupResult.Properties['distinguishedName'][0]
                            $groupEntry = [ADSI]"LDAP://$groupDN"

                            # Get member DNs
                            $memberDNs = @()
                            try
                            {
                                $memberDNs = @($groupEntry.psbase.InvokeGet("member"))
                            }
                            catch
                            {
                                # Try alternative method
                                $memberDNs = @($groupEntry.psbase.Properties['member'])
                            }

                            # Process each member DN
                            foreach ($memberDN in $memberDNs)
                            {
                                try
                                {
                                    # Parse CN from DN: CN=name,OU=...,DC=...
                                    if ($memberDN -match 'CN=([^,]+)')
                                    {
                                        $samAccount = $Matches[1]
                                        $displayName = $samAccount

                                        # Try to get actual sAMAccountName and displayName
                                        try
                                        {
                                            $memberEntry = [ADSI]"LDAP://$memberDN"
                                            $sam = $memberEntry.psbase.InvokeGet("sAMAccountName")
                                            $disp = $memberEntry.psbase.InvokeGet("displayName")
                                            if ($sam) { $samAccount = $sam }
                                            if ($disp) { $displayName = $disp }
                                        }
                                        catch { }

                                        # Determine object class
                                        $objectClass = "Unknown"
                                        try
                                        {
                                            $cls = $memberEntry.psbase.InvokeGet("objectClass")
                                            if ($cls -is [array]) { $objectClass = $cls[-1] } else { $objectClass = $cls }
                                        }
                                        catch { }

                                        $members.Add([PSCustomObject]@{
                                                SamAccountName = $samAccount
                                                DisplayName    = $displayName
                                                ObjectClass    = $objectClass
                                            })
                                    }
                                }
                                catch
                                {
                                    Invoke-sqmLogging -Message "[$cleanGroup] Fehler bei Member $memberDN : $_" -FunctionName $functionName -Level "WARNING"
                                }
                            }
                            $methodUsed = "LDAP-Query"
                            Invoke-sqmLogging -Message "[$cleanGroup] $($members.Count) Members via LDAP" -FunctionName $functionName -Level "VERBOSE"
                        }
                        else
                        {
                            Invoke-sqmLogging -Message "[$cleanGroup] Gruppe nicht gefunden in LDAP" -FunctionName $functionName -Level "WARNING"
                        }
                    }
                    catch
                    {
                        $errMsg = "[$cleanGroup] LDAP-Abfrage fehlgeschlagen: $_"
                        Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
                    }
                }

                # Write report files
                $txtFile = $null
                $csvFile = $null
                $htmlFile = $null

                if ($PSCmdlet.ShouldProcess($cleanGroup, "Erstelle Bericht"))
                {
                    # Create output directory
                    if (-not (Test-Path $OutputPath))
                    {
                        New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
                    }

                    # TXT report
                    $safeGroup = $cleanGroup -replace '[\\/:*?"<>|]', '_'
                    $txtFile = Join-Path $OutputPath "ADGroupMembers_${safeGroup}_${datestamp}.txt"
                    $csvFile = Join-Path $OutputPath "ADGroupMembers_${safeGroup}_${datestamp}.csv"
                    $htmlFile = Join-Path $OutputPath "ADGroupMembers_${safeGroup}_${datestamp}.html"

                    $lines = @(
                        "# sqmSQLTool - www.powershelldba.de"
                        "# ================================================================"
                        "# AD Group Members Report"
                        "# Gruppe    : $cleanGroup"
                        "# Domain    : $targetDomain"
                        "# Methode   : $methodUsed"
                        "# Erstellt  : $timestamp"
                        "# Members   : $($members.Count)"
                        "# ================================================================"
                        ""
                        ("{0,-30} {1,-35} {2,-15}" -f 'SamAccountName', 'DisplayName', 'Type')
                        ("-" * 80)
                    )

                    foreach ($member in ($members | Sort-Object SamAccountName))
                    {
                        $lines += ("{0,-30} {1,-35} {2,-15}" -f $member.SamAccountName, $member.DisplayName, $member.ObjectClass)
                    }

                    $lines | Out-File -FilePath $txtFile -Encoding UTF8 -Force
                    $members | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation -Force

                    # HTML report (same theme/style as the rest of the module)
                    $rowsHtml = foreach ($m in ($members | Sort-Object SamAccountName))
                    {
                        "<tr><td>$([System.Net.WebUtility]::HtmlEncode($m.SamAccountName))</td><td>$([System.Net.WebUtility]::HtmlEncode($m.DisplayName))</td><td>$($m.ObjectClass)</td></tr>"
                    }
                    $bodyHtml = "<p>Gruppe: $([System.Net.WebUtility]::HtmlEncode($cleanGroup)) | Domain: $([System.Net.WebUtility]::HtmlEncode($targetDomain)) | Methode: $methodUsed | Mitglieder: $($members.Count)</p>" +
                        "<table><tr><th>SamAccountName</th><th>DisplayName</th><th>Type</th></tr>" +
                        ($rowsHtml -join '') + "</table>"
                    $html = ConvertTo-sqmHtmlReport -Title "AD Group Members - $cleanGroup" -Subtitle "Erstellt: $timestamp" -BodyHtml $bodyHtml
                    $html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force

                    Invoke-sqmOpenReport -HtmlFile $htmlFile -TxtFile $txtFile -NoOpen:$NoOpen

                    Invoke-sqmLogging -Message "[$cleanGroup] Bericht: $htmlFile" -FunctionName $functionName -Level "INFO"
                }

                # Result object
                $allResults.Add([PSCustomObject]@{
                        GroupName   = $cleanGroup
                        Domain      = $targetDomain
                        Method      = $methodUsed
                        MemberCount = $members.Count
                        Members     = $members
                        Timestamp   = $timestamp
                        TxtFile     = $txtFile
                        CsvFile     = $csvFile
                        HtmlFile    = $htmlFile
                        Status      = if ($members.Count -gt 0) { 'OK' } else { 'Warning' }
                    })
            }
            catch
            {
                $errMsg = "Fehler bei Gruppe '$group': $($_.Exception.Message)"
                Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
                $allResults.Add([PSCustomObject]@{
                        GroupName   = $group
                        Domain      = $Domain
                        Method      = 'NONE'
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
        Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Gruppen verarbeitet." -FunctionName $functionName -Level "INFO"
        return $allResults
    }
}

