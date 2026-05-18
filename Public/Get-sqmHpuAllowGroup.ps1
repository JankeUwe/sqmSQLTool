<#
    .SYNOPSIS
        Sucht die HPU-Allow-Gruppe im AD anhand konfigurierbarer Domain-/Gruppen-Mappings.

    .DESCRIPTION
        Liest das Domain-Gruppen-Mapping aus der Modulkonfiguration (Key: HpuDomainGroupMap).
        Jeder Eintrag enthaelt ein DomainPattern (Wildcard) und ein GroupNamePattern (sAMAccountName-Filter).
        Die aktuelle Maschinen-Domain wird gegen alle Eintraege geprueft; der erste Treffer gewinnt.

        Konfiguration ueber Set-sqmConfig:
            Set-sqmConfig -HpuDomainGroupMap @(
                [PSCustomObject]@{ DomainPattern = 'bayernlb.sfinance.net'; GroupNamePattern = 'Fg_DC_AouAllowManageAuditSecLogSrvAll_Mod' },
                [PSCustomObject]@{ DomainPattern = '*.sfinance.net';        GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' },
                [PSCustomObject]@{ DomainPattern = '*';                     GroupNamePattern = 'Rg_DC_AouAllowManageAuditSecLogSrvAll_Mod' }
            )

    .OUTPUTS
        [string] DistinguishedName der gefundenen Gruppe, oder $null.

    .EXAMPLE
        Get-sqmHpuAllowGroup

    .EXAMPLE
        Get-sqmHpuAllowGroup -EnableException
#>
function Get-sqmHpuAllowGroup
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    $functionName = $MyInvocation.MyCommand.Name

    # ?? 1. Domain des lokalen Rechners ermitteln ????????????????????????????
    try
    {
        $currentDomain = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Domain
    }
    catch
    {
        $msg = "Domain konnte nicht ermittelt werden: $($_.Exception.Message)"
        Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
        if ($EnableException) { throw $msg }
        return $null
    }

    Invoke-sqmLogging -Message "Starte $functionName. Lokale Domain: '$currentDomain'" `
                      -FunctionName $functionName -Level 'INFO'

    # ?? 2. Mapping aus der Konfiguration lesen ??????????????????????????????
    $domainGroupMap = Get-sqmConfig -Key 'HpuDomainGroupMap'

    if (-not $domainGroupMap -or $domainGroupMap.Count -eq 0)
    {
        $msg = "Konfigurationsschluessel 'HpuDomainGroupMap' ist nicht gesetzt. " +
               "Bitte Set-sqmConfig -HpuDomainGroupMap <...> ausfuehren."
        Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
        if ($EnableException) { throw $msg }
        Write-Warning $msg
        return $null
    }

    # ?? 3. Passenden Mapping-Eintrag per Wildcard-Match suchen ?????????????
    $matchedEntry = $null
    foreach ($entry in $domainGroupMap)
    {
        if ($currentDomain -like $entry.DomainPattern)
        {
            $matchedEntry = $entry
            Invoke-sqmLogging -Message "Domain '$currentDomain' trifft Pattern '$($entry.DomainPattern)'." `
                              -FunctionName $functionName -Level 'INFO'
            break
        }
    }

    if (-not $matchedEntry)
    {
        $msg = "Kein Mapping-Eintrag fuer Domain '$currentDomain' gefunden."
        Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
        if ($EnableException) { throw $msg }
        Write-Warning $msg
        return $null
    }

    $groupNamePattern = $matchedEntry.GroupNamePattern

    # ?? 4. AD-Suche ????????????????????????????????????????????????????????
    try
    {
        $ldapFilter = "(&(objectCategory=group)(sAMAccountName=*$groupNamePattern))"
        Invoke-sqmLogging -Message "LDAP-Filter: $ldapFilter" -FunctionName $functionName -Level 'INFO'

        $searcher                    = [adsisearcher]$ldapFilter
        $searcher.PageSize           = 20
        foreach ($prop in @('name', 'distinguishedname'))
        {
            $searcher.PropertiesToLoad.Add($prop) | Out-Null
        }

        $result = $searcher.FindOne()
    }
    catch
    {
        $msg = "AD-Suche fehlgeschlagen: $($_.Exception.Message)"
        Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'ERROR'
        if ($EnableException) { throw $msg }
        Write-Warning $msg
        return $null
    }

    # ?? 5. Ergebnis auswerten ???????????????????????????????????????????????
    if ($null -eq $result)
    {
        $msg = "Keine HPU-Allow-Gruppe '*$groupNamePattern' in Domain '$currentDomain' gefunden."
        Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level 'WARNING'
        if ($EnableException) { throw $msg }
        Write-Warning $msg
        return $null
    }

    $dn = ($result.Properties['distinguishedname'])[0]
    Invoke-sqmLogging -Message "Gruppe gefunden: $dn" -FunctionName $functionName -Level 'INFO'
    return $dn
}
