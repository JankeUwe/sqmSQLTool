<#
.SYNOPSIS
    Generates a random, policy-compliant SA password.

.DESCRIPTION
    Creates a cryptographically secure password that meets the SQL Server
    password policy:
        - Minimum length configurable (default: 20 characters)
        - At least 1 uppercase letter (A-Z)
        - At least 1 lowercase letter (a-z)
        - At least 1 digit (0-9)
        - At least 1 special character from the defined set

    Optional file export: the password is written to a text file, DPAPI-
    encrypted (ConvertFrom-SecureString).
    Only the user/computer that exported it can read the file again.

.PARAMETER Length
    Length of the password. Default: 20. Minimum: 12.

.PARAMETER ExportPath
    Optional path for the encrypted password file.
    E.g.: C:\System\Passwords\sa_password.txt
    If empty: no export.

.OUTPUTS
    [SecureString] - The generated password as a SecureString.
    (Plain text is not output - only on explicit request via [PSCredential].)

.EXAMPLE
    $pwd = New-sqmRandomSaPassword
    # Returns a SecureString

.EXAMPLE
    $pwd = New-sqmRandomSaPassword -Length 24 -ExportPath 'C:\System\Passwords\sa.txt'
    # SecureString + DPAPI export to C:\System\Passwords\sa.txt

.EXAMPLE
    # Show plain text (debugging only):
    $pwd = New-sqmRandomSaPassword
    $cred = New-Object PSCredential('sa', $pwd)
    $cred.GetNetworkCredential().Password

.NOTES
    DPAPI export: the file can only be decrypted from the same Windows user
    profile on the same computer.
    For production environments: use Key Vault or CyberArk instead.
#>
function New-sqmRandomSaPassword
{
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param (
        [Parameter(Mandatory = $false)]
        [ValidateRange(12, 128)]
        [int]$Length = 20,

        [Parameter(Mandatory = $false)]
        [string]$ExportPath
    )

    $functionName = $MyInvocation.MyCommand.Name

    function _Log { param([string]$Msg, [string]$Level = 'INFO')
        Write-Verbose "[$functionName] $Msg"
        try { Invoke-sqmLogging -Message $Msg -FunctionName $functionName -Level $Level } catch { }
    }

    # --- Zeichenvorrat ---
    $charUpper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'    # ohne I und O (Verwechslungsgefahr)
    $charLower   = 'abcdefghjkmnpqrstuvwxyz'      # ohne i, l, o
    $charDigits  = '23456789'                      # ohne 0 und 1
    $charSpecial = '!@#$%^&*()-_=+[]{}|;:,.<>?'

    $allChars = ($charUpper + $charLower + $charDigits + $charSpecial).ToCharArray()

    # --- Kryptografisch sicherer Zufallsgenerator ---
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    function _GetRandomChar {
        param([char[]]$Pool)
        $bytes = New-Object byte[] 4
        $rng.GetBytes($bytes)
        $idx = [math]::Abs([BitConverter]::ToInt32($bytes, 0)) % $Pool.Length
        return $Pool[$idx]
    }

    try
    {
        # Garantiere Zeichenklassen-Anforderungen
        $pwChars = [System.Collections.Generic.List[char]]::new()
        $pwChars.Add((_GetRandomChar $charUpper.ToCharArray()))
        $pwChars.Add((_GetRandomChar $charLower.ToCharArray()))
        $pwChars.Add((_GetRandomChar $charDigits.ToCharArray()))
        $pwChars.Add((_GetRandomChar $charSpecial.ToCharArray()))

        # Restliche Zeichen aus dem vollen Pool
        for ($i = 4; $i -lt $Length; $i++)
        {
            $pwChars.Add((_GetRandomChar $allChars))
        }

        # Fisher-Yates-Shuffle fuer kryptografisch sichere Permutation
        for ($i = $pwChars.Count - 1; $i -gt 0; $i--)
        {
            $bytes2 = New-Object byte[] 4
            $rng.GetBytes($bytes2)
            $j = [math]::Abs([BitConverter]::ToInt32($bytes2, 0)) % ($i + 1)
            $tmp           = $pwChars[$i]
            $pwChars[$i]   = $pwChars[$j]
            $pwChars[$j]   = $tmp
        }

        $plainText  = -join $pwChars
        $secureString = ConvertTo-SecureString -String $plainText -AsPlainText -Force

        _Log "Passwort generiert (Laenge: $Length Zeichen)."

        # --- Optionaler DPAPI-Export ---
        if ($ExportPath -and $ExportPath -ne '')
        {
            $exportDir = Split-Path $ExportPath -Parent
            if ($exportDir -and -not (Test-Path $exportDir))
            {
                New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
            }

            $encrypted = ConvertFrom-SecureString $secureString
            Set-Content -Path $ExportPath -Value $encrypted -Encoding UTF8 -Force
            _Log "Passwort DPAPI-verschluesselt exportiert: $ExportPath"
            Write-Verbose "SA-Passwort exportiert nach: $ExportPath"
        }

        # Klartext aus dem Speicher loeschen
        $plainText = $null
        [System.GC]::Collect()

        return $secureString
    }
    finally
    {
        if ($null -ne $rng) { $rng.Dispose() }
    }
}
