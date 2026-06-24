<#
.SYNOPSIS
    Ermittelt alle Computer-Objekte aus einer bestimmten AD-OU und gibt sie
    als pipefaehige Objekte aus.

.DESCRIPTION
    Durchsucht Active Directory (via ADSI, kein ActiveDirectory-Modul erforderlich)
    nach allen Computer-Objekten unterhalb einer OU mit dem angegebenen Namen.

    Die Ausgabe-Objekte enthalten eine SqlInstance-Eigenschaft und koennen direkt
    an beliebige sqmSQLTool-Funktionen weitergeleitet werden:

        Get-sqmServersFromOU | ForEach-Object {
            Sync-sqmBackupExcludeTable -SqlInstance $_.SqlInstance
        }

.PARAMETER OUName
    Name der OU (nicht der vollstaendige LDAP-Pfad).
    Beispiel: 'srvDatabase'
    Standard: 'srvDatabase'

.PARAMETER Domain
    FQDN der Domain. Standard: aktuelle Domain des ausfuehrenden Benutzers.

.PARAMETER SearchBase
    Expliziter LDAP-Suchpfad (DistinguishedName der OU).
    Wenn angegeben, wird OUName ignoriert.
    Beispiel: 'OU=srvDatabase,OU=Server,DC=contoso,DC=com'

.PARAMETER Recurse
    Sucht auch in untergeordneten OUs (Standard: $true).

.PARAMETER EnableException
    Loest bei Fehlern sofort eine Exception aus.

.OUTPUTS
    PSCustomObject mit: Name, FQDN, SqlInstance, OU, Domain, OperatingSystem

.EXAMPLE
    # Alle SQL-Server ausgeben
    Get-sqmServersFromOU

.EXAMPLE
    # Andere OU
    Get-sqmServersFromOU -OUName 'srvApp'

.EXAMPLE
    # Expliziter Domain-Name
    Get-sqmServersFromOU -OUName 'srvDatabase' -Domain 'contoso.com'

.EXAMPLE
    # Direkt an sqmSQLTool-Funktion weiterleiten
    Get-sqmServersFromOU | ForEach-Object {
        Sync-sqmBackupExcludeTable -SqlInstance $_.SqlInstance
    }

.EXAMPLE
    # Backup-Exclude-Trigger auf allen DB-Servern registrieren
    Get-sqmServersFromOU | ForEach-Object {
        Register-sqmBackupExcludeTrigger -SqlInstance $_.SqlInstance
    }

.NOTES
    Benoetigt keine ActiveDirectory-Modulinstallation.
    Benoetigt Lesezugriff auf Active Directory.
#>
function Get-sqmServersFromOU
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$OUName = 'srvDatabase',

        [Parameter(Mandatory = $false)]
        [string]$Domain,

        [Parameter(Mandatory = $false)]
        [string]$SearchBase,

        [Parameter(Mandatory = $false)]
        [bool]$Recurse = $true,

        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    $functionName = $MyInvocation.MyCommand.Name

    try
    {
        # ── Domain ermitteln ─────────────────────────────────────────────
        if ([string]::IsNullOrWhiteSpace($Domain))
        {
            $Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name
        }

        $domainDN = 'DC=' + ($Domain -split '\.' -join ',DC=')
        Invoke-sqmLogging -Message "[$functionName] Domain: $Domain | DN: $domainDN" -FunctionName $functionName -Level 'INFO'

        # ── SearchBase ermitteln ─────────────────────────────────────────
        if ([string]::IsNullOrWhiteSpace($SearchBase))
        {
            # OU per Name suchen
            $ouSearcher = [System.DirectoryServices.DirectorySearcher]::new(
                [System.DirectoryServices.DirectoryEntry]::new("LDAP://$domainDN")
            )
            $ouSearcher.Filter      = "(&(objectClass=organizationalUnit)(ou=$OUName))"
            $ouSearcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
            $ouSearcher.PropertiesToLoad.AddRange([string[]]@('distinguishedName', 'ou'))

            $ouResult = $ouSearcher.FindOne()
            if (-not $ouResult)
            {
                $errMsg = "OU '$OUName' wurde in Domain '$Domain' nicht gefunden."
                Invoke-sqmLogging -Message "[$functionName] $errMsg" -FunctionName $functionName -Level 'ERROR'
                if ($EnableException) { throw $errMsg }
                Write-Error $errMsg
                return
            }

            $SearchBase = $ouResult.Properties['distinguishedname'][0]
            Invoke-sqmLogging -Message "[$functionName] OU gefunden: $SearchBase" -FunctionName $functionName -Level 'INFO'
        }

        Write-Host "Suche Computer in OU: $SearchBase" -ForegroundColor Cyan

        # ── Computer-Objekte laden ───────────────────────────────────────
        $scope = if ($Recurse) {
            [System.DirectoryServices.SearchScope]::Subtree
        } else {
            [System.DirectoryServices.SearchScope]::OneLevel
        }

        $compSearcher = [System.DirectoryServices.DirectorySearcher]::new(
            [System.DirectoryServices.DirectoryEntry]::new("LDAP://$SearchBase")
        )
        $compSearcher.Filter      = '(objectClass=computer)'
        $compSearcher.SearchScope = $scope
        $compSearcher.PageSize    = 1000
        $compSearcher.PropertiesToLoad.AddRange([string[]]@(
            'name', 'dnshostname', 'distinguishedname', 'operatingsystem', 'description'
        ))

        $results = $compSearcher.FindAll()

        if ($results.Count -eq 0)
        {
            Write-Warning "Keine Computer in OU '$SearchBase' gefunden."
            return
        }

        Write-Host "$($results.Count) Server gefunden:" -ForegroundColor Green

        $servers = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($r in $results)
        {
            $name = $r.Properties['name'][0]
            $fqdn = if ($r.Properties['dnshostname'].Count -gt 0) {
                $r.Properties['dnshostname'][0]
            } else {
                "$name.$Domain"
            }

            # OU aus DistinguishedName extrahieren (erster OU=-Teil)
            $dn        = $r.Properties['distinguishedname'][0]
            $ouPart    = ($dn -split ',' | Where-Object { $_ -match '^OU=' } | Select-Object -First 1) -replace '^OU=', ''
            $os        = if ($r.Properties['operatingsystem'].Count -gt 0) { $r.Properties['operatingsystem'][0] } else { '' }
            $desc      = if ($r.Properties['description'].Count -gt 0) { $r.Properties['description'][0] } else { '' }

            $obj = [PSCustomObject]@{
                Name            = $name
                FQDN            = $fqdn
                SqlInstance     = $fqdn      # direkt an -SqlInstance verwendbar
                OU              = $ouPart
                Domain          = $Domain
                OperatingSystem = $os
                Description     = $desc
            }

            Write-Host "  - $name  [$os]" -ForegroundColor White
            $servers.Add($obj)
        }

        Write-Host ""
        Invoke-sqmLogging -Message "[$functionName] $($servers.Count) Server aus OU '$OUName' ermittelt." -FunctionName $functionName -Level 'INFO'

        return $servers.ToArray()
    }
    catch
    {
        $errMsg = "Fehler in $functionName`: $($_.Exception.Message)"
        Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
        if ($EnableException) { throw }
        Write-Error $errMsg
    }
    finally
    {
        if ($results) { $results.Dispose() }
    }
}
