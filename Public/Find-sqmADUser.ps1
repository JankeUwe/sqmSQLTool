<#
.SYNOPSIS
    Durchsucht Active Directory nach Benutzerkonten anhand eines Namensmusters.

.DESCRIPTION
    Sucht AD-Benutzerkonten, deren SamAccountName einem Wildcard-Muster entspricht,
    z.B. alle Service-Accounts mit dem Praefix "so_".

    Verwendet Wildcard-Syntax wie bei Get-ADUser -Filter bzw. dem PowerShell
    -like-Operator: '*' fuer beliebig viele Zeichen, '?' fuer genau ein Zeichen.
    Beispiel: 'so_*' findet 'so_backup', 'so_monitoring', 'so_svc01', ...

    Methoden:
    1. Get-ADUser -Filter (falls ActiveDirectory-Modul verfuegbar) - liefert die meisten Details
    2. LDAP direct query via DirectorySearcher (Fallback, kein Modul erforderlich) -
       unterstuetzt nur '*' als Wildcard, '?' wird dabei ebenfalls als '*' behandelt.

.PARAMETER Pattern
    Wildcard-Muster fuer den SamAccountName. Pipeline-faehig.
    Beispiel: 'so_*', 'svc-sql??', '*admin*'

.PARAMETER Domain
    Optional: AD-Domain (z.B. "contoso.com"). Wenn nicht angegeben, wird die
    aktuelle Domain des ausfuehrenden Benutzers verwendet.

.PARAMETER SearchBase
    Optional: Expliziter LDAP-Suchpfad (DistinguishedName einer OU), um die Suche
    einzuschraenken. Beispiel: 'OU=ServiceAccounts,DC=contoso,DC=com'

.PARAMETER DomainController
    Optional: Ziel-DC. Wird nur im RSAT-Pfad (Get-ADUser) verwendet.

.PARAMETER EnableException
    Loest bei Fehlern eine Exception aus, statt nur eine Warnung/Write-Error auszugeben.

.OUTPUTS
    PSCustomObject mit: SamAccountName, DisplayName, EmailAddress, Enabled,
    DistinguishedName, LastLogonDate, Domain, Source ('RSAT' oder 'LDAP')

.EXAMPLE
    Find-sqmADUser -Pattern 'so_*'

    Findet alle Konten, deren SamAccountName mit "so_" beginnt.

.EXAMPLE
    Find-sqmADUser -Pattern 'svc-*' -Domain 'contoso.com'

.EXAMPLE
    Find-sqmADUser -Pattern '*admin*' -SearchBase 'OU=Admins,DC=contoso,DC=com'

.EXAMPLE
    'so_*', 'svc-*' | Find-sqmADUser | Where-Object Enabled -eq $false

.NOTES
    Author: sqmSQLTool
    Benoetigt Lesezugriff auf Active Directory. Kein ActiveDirectory-Modul zwingend
    erforderlich (LDAP-Fallback via ADSI/DirectorySearcher).
#>
function Find-sqmADUser
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Pattern,

        [Parameter(Mandatory = $false)]
        [string]$Domain,

        [Parameter(Mandatory = $false)]
        [string]$SearchBase,

        [Parameter(Mandatory = $false)]
        [string]$DomainController,

        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name
        $allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

        # ── Domain ermitteln (einmalig) ──────────────────────────────────
        $targetDomain = $Domain
        if ([string]::IsNullOrWhiteSpace($targetDomain))
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

        # ── RSAT-Verfuegbarkeit einmalig pruefen ─────────────────────────
        $useRSAT = $false
        if (Get-Module -Name ActiveDirectory -ListAvailable -ErrorAction SilentlyContinue)
        {
            try
            {
                Import-Module ActiveDirectory -ErrorAction Stop
                $useRSAT = $true
                Invoke-sqmLogging -Message "ActiveDirectory-Modul geladen (RSAT-Pfad aktiv)." -FunctionName $functionName -Level 'INFO'
            }
            catch
            {
                Invoke-sqmLogging -Message "ActiveDirectory-Modul nicht ladbar: $_ - Fallback auf LDAP." -FunctionName $functionName -Level 'VERBOSE'
            }
        }
        else
        {
            Invoke-sqmLogging -Message "ActiveDirectory-Modul nicht installiert - Fallback auf LDAP." -FunctionName $functionName -Level 'VERBOSE'
        }

        Invoke-sqmLogging -Message "Starte $functionName | Domain: $targetDomain" -FunctionName $functionName -Level 'INFO'
    }

    process
    {
        foreach ($pat in $Pattern)
        {
            Invoke-sqmLogging -Message "Suche AD-Benutzer nach Muster '$pat'." -FunctionName $functionName -Level 'VERBOSE'

            #region --- RSAT-Pfad ---
            if ($useRSAT)
            {
                try
                {
                    $params = @{
                        Filter      = "SamAccountName -like '$pat'"
                        Properties  = @('DisplayName', 'EmailAddress', 'Enabled', 'LastLogonDate')
                        ErrorAction = 'Stop'
                    }
                    if ($SearchBase) { $params['SearchBase'] = $SearchBase }
                    if ($DomainController) { $params['Server'] = $DomainController }

                    $adUsers = @(Get-ADUser @params)

                    foreach ($u in $adUsers)
                    {
                        $allResults.Add([PSCustomObject]@{
                                SamAccountName    = $u.SamAccountName
                                DisplayName       = $u.DisplayName
                                EmailAddress      = $u.EmailAddress
                                Enabled           = $u.Enabled
                                DistinguishedName = $u.DistinguishedName
                                LastLogonDate     = $u.LastLogonDate
                                Domain            = $targetDomain
                                Source            = 'RSAT'
                            })
                    }

                    Invoke-sqmLogging -Message "[$pat] $($adUsers.Count) Treffer via Get-ADUser." -FunctionName $functionName -Level 'INFO'
                    continue
                }
                catch
                {
                    Invoke-sqmLogging -Message "[$pat] RSAT-Fehler: $_ - Fallback auf LDAP." -FunctionName $functionName -Level 'WARNING'
                }
            }
            #endregion

            #region --- LDAP-Fallback ---
            try
            {
                $root = if ($SearchBase)
                {
                    [System.DirectoryServices.DirectoryEntry]::new("LDAP://$SearchBase")
                }
                else
                {
                    $domainDN = 'DC=' + ($targetDomain -split '\.' -join ',DC=')
                    [System.DirectoryServices.DirectoryEntry]::new("LDAP://$domainDN")
                }

                # LDAP kennt nur '*' als Wildcard - '?' wird ebenfalls auf '*' abgebildet
                $ldapPattern = $pat -replace '\?', '*'

                $searcher = [System.DirectoryServices.DirectorySearcher]::new($root)
                $searcher.Filter = "(&(objectClass=user)(objectCategory=person)(sAMAccountName=$ldapPattern))"
                $searcher.PageSize = 1000
                $searcher.PropertiesToLoad.AddRange([string[]]@(
                        'sAMAccountName', 'displayName', 'mail', 'userAccountControl',
                        'distinguishedName', 'lastLogonTimestamp'
                    ))

                $results = $searcher.FindAll()

                foreach ($r in $results)
                {
                    $uac = if ($r.Properties['useraccountcontrol'].Count -gt 0) { [int]$r.Properties['useraccountcontrol'][0] } else { 0 }
                    $enabled = -not [bool]($uac -band 0x0002)

                    $lastLogon = $null
                    if ($r.Properties['lastlogontimestamp'].Count -gt 0)
                    {
                        $llRaw = [long]$r.Properties['lastlogontimestamp'][0]
                        if ($llRaw -gt 0) { $lastLogon = [datetime]::FromFileTime($llRaw) }
                    }

                    $allResults.Add([PSCustomObject]@{
                            SamAccountName    = $r.Properties['samaccountname'][0]
                            DisplayName       = if ($r.Properties['displayname'].Count -gt 0) { $r.Properties['displayname'][0] } else { '' }
                            EmailAddress      = if ($r.Properties['mail'].Count -gt 0) { $r.Properties['mail'][0] } else { '' }
                            Enabled           = $enabled
                            DistinguishedName = $r.Properties['distinguishedname'][0]
                            LastLogonDate     = $lastLogon
                            Domain            = $targetDomain
                            Source            = 'LDAP'
                        })
                }

                Invoke-sqmLogging -Message "[$pat] $($results.Count) Treffer via LDAP." -FunctionName $functionName -Level 'INFO'
                $results.Dispose()
            }
            catch
            {
                $errMsg = "Fehler bei Muster '$pat': $($_.Exception.Message)"
                Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
                if ($EnableException) { throw }
                Write-Error $errMsg
            }
            #endregion
        }
    }

    end
    {
        Invoke-sqmLogging -Message "$functionName abgeschlossen. $($allResults.Count) Benutzer gefunden." -FunctionName $functionName -Level 'INFO'
        return $allResults.ToArray()
    }
}
