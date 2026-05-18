function Get-sqmADAccountStatus {
    <#
    .SYNOPSIS
        Checks the status of an Active Directory user account.

    .DESCRIPTION
        Determines the account status using the ActiveDirectory module (RSAT) with
        automatic fallback to ADSI if RSAT is not available.
        Returns a detailed PSObject with Enabled, LockedOut, PasswordExpired
        and AccountExpired.

    .PARAMETER SamAccountName
        The SamAccountName of the AD account to check.

    .PARAMETER DomainController
        Optional target DC. Only used via the RSAT path.

    .OUTPUTS
        PSCustomObject with the following properties:
            SamAccountName  [string]
            Enabled         [bool]
            LockedOut       [bool]
            PasswordExpired [bool]
            AccountExpired  [bool]
            Source          [string]  'RSAT' or 'ADSI'
            QueryTime       [datetime]
            ErrorMessage    [string]  empty if successful

    .EXAMPLE
        Get-sqmADAccountStatus -SamAccountName 'jdoe'

    .EXAMPLE
        'jdoe','jsmith' | Get-sqmADAccountStatus

    .EXAMPLE
        Get-sqmADAccountStatus -SamAccountName 'jdoe' -DomainController 'DC01'
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]] $SamAccountName,

        [Parameter()]
        [string] $DomainController
    )

    begin {
        #region --- Modul-Verfuegbarkeit einmalig pruefen ---
        $useRSAT = $false
        if (Get-Module -Name ActiveDirectory -ListAvailable) {
            try {
                Import-Module ActiveDirectory -ErrorAction Stop
                $useRSAT = $true
                Write-Verbose 'ActiveDirectory-Modul geladen (RSAT-Pfad aktiv).'
            }
            catch {
                Write-Verbose "ActiveDirectory-Modul nicht ladbar: $_  - Fallback auf ADSI."
            }
        }
        else {
            Write-Verbose 'ActiveDirectory-Modul nicht installiert - Fallback auf ADSI.'
        }

        # Hilfsfunktion: Ergebnis-Objekt erzeugen
        function New-ResultObject {
            param (
                [string]   $Sam,
                [bool]     $Enabled        = $false,
                [bool]     $LockedOut      = $false,
                [bool]     $PwdExpired     = $false,
                [bool]     $AcctExpired    = $false,
                [string]   $Source         = '',
                [string]   $ErrorMessage   = ''
            )
            [PSCustomObject]@{
                SamAccountName  = $Sam
                Enabled         = $Enabled
                LockedOut       = $LockedOut
                PasswordExpired = $PwdExpired
                AccountExpired  = $AcctExpired
                Source          = $Source
                QueryTime       = (Get-Date)
                ErrorMessage    = $ErrorMessage
            }
        }

        #region --- ADSI-Hilfsfunktion ---
        function Get-ADAccountStatusViaADSI {
            param ([string] $Sam)

            # Searcher aufbauen
            $searcher = [adsisearcher]"(sAMAccountName=$Sam)"
            $searcher.PropertiesToLoad.AddRange(@(
                'sAMAccountName',
                'userAccountControl',
                'lockoutTime',
                'pwdLastSet',
                'accountExpires',
                'msDS-UserPasswordExpiryTimeComputed'
            )) | Out-Null
            $searcher.SizeLimit = 1

            $entry = $searcher.FindOne()
            if (-not $entry) {
                throw "Konto '$Sam' wurde im Verzeichnis nicht gefunden."
            }

            $uac = [int]$entry.Properties['useraccountcontrol'][0]

            # Enabled: Bit 2 (0x0002) = disabled
            $enabled   = -not [bool]($uac -band 0x0002)

            # LockedOut: Bit 16 (0x0010) oder lockoutTime > 0
            $lockedBit = [bool]($uac -band 0x0010)
            $lockoutTimeRaw = $entry.Properties['lockouttime']
            $lockedTime = $false
            if ($lockoutTimeRaw.Count -gt 0) {
                $lt = [long]$lockoutTimeRaw[0]
                $lockedTime = ($lt -gt 0)
            }
            $lockedOut = $lockedBit -or $lockedTime

            # PasswordExpired: Bit 8388608 (0x800000) oder msDS-Attribut
            $pwdExpiredBit = [bool]($uac -band 0x800000)
            $pwdExpired = $pwdExpiredBit

            if (-not $pwdExpired) {
                $expiryRaw = $entry.Properties['msds-userpasswordexpirytimecomputed']
                if ($expiryRaw.Count -gt 0) {
                    $expiryFt = [long]$expiryRaw[0]
                    # 0 = laeuft nie ab, 9223372036854775807 = nie
                    if ($expiryFt -gt 0 -and $expiryFt -ne [long]::MaxValue) {
                        $expiryDate = [datetime]::FromFileTime($expiryFt)
                        $pwdExpired = ($expiryDate -lt (Get-Date))
                    }
                }
            }

            # AccountExpired
            $acctExpired = $false
            $acctExpiresRaw = $entry.Properties['accountexpires']
            if ($acctExpiresRaw.Count -gt 0) {
                $ae = [long]$acctExpiresRaw[0]
                # 0 und Int64.MaxValue bedeuten "laeuft nie ab"
                if ($ae -gt 0 -and $ae -ne [long]::MaxValue) {
                    $expDate = [datetime]::FromFileTime($ae)
                    $acctExpired = ($expDate -lt (Get-Date))
                }
            }

            return [PSCustomObject]@{
                Enabled         = $enabled
                LockedOut       = $lockedOut
                PasswordExpired = $pwdExpired
                AccountExpired  = $acctExpired
            }
        }
        #endregion
    }

    process {
        foreach ($sam in $SamAccountName) {
            Write-Verbose "Verarbeite Konto: $sam"

            #region --- RSAT-Pfad ---
            if ($useRSAT) {
                try {
                    $params = @{
                        Identity    = $sam
                        Properties  = @(
                            'Enabled',
                            'LockedOut',
                            'PasswordExpired',
                            'AccountExpirationDate'   # 'AccountExpired' ist keine abrufbare Property
                        )
                        ErrorAction = 'Stop'
                    }
                    if ($DomainController) { $params['Server'] = $DomainController }

                    $adUser = Get-ADUser @params

                    # AccountExpired: ExpirationDate vorhanden und in der Vergangenheit?
                    $acctExpired = ($null -ne $adUser.AccountExpirationDate) -and
                                   ($adUser.AccountExpirationDate -lt (Get-Date))

                    New-ResultObject `
                        -Sam         $sam `
                        -Enabled     ([bool]$adUser.Enabled) `
                        -LockedOut   ([bool]$adUser.LockedOut) `
                        -PwdExpired  ([bool]$adUser.PasswordExpired) `
                        -AcctExpired $acctExpired `
                        -Source      'RSAT'
                    continue
                }
                catch {
                    # Konto nicht gefunden ? direkt Fehlerobjekt, kein ADSI-Fallback
                    if ($_.Exception.GetType().Name -eq 'ADIdentityNotFoundException') {
                        New-ResultObject -Sam $sam -ErrorMessage "Konto nicht gefunden: $_" -Source 'RSAT'
                        continue
                    }
                    Write-Verbose "RSAT-Fehler fuer '$sam': $_ - Fallback auf ADSI."
                }
            }
            #endregion

            #region --- ADSI-Fallback ---
            try {
                $adsi = Get-ADAccountStatusViaADSI -Sam $sam

                New-ResultObject `
                    -Sam        $sam `
                    -Enabled    $adsi.Enabled `
                    -LockedOut  $adsi.LockedOut `
                    -PwdExpired $adsi.PasswordExpired `
                    -AcctExpired $adsi.AccountExpired `
                    -Source     'ADSI'
            }
            catch {
                New-ResultObject -Sam $sam -ErrorMessage $_.ToString() -Source 'ADSI'
            }
            #endregion
        }
    }
}