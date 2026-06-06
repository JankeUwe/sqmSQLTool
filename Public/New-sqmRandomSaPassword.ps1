<#
.SYNOPSIS
    Generiert ein zufaelliges, richtlinienkonformes SA-Passwort.

.DESCRIPTION
    Erstellt ein kryptografisch sicheres Passwort das die SQL Server
    Passwort-Richtlinie erfuellt:
        - Mindestlaenge konfigurierbar (Standard: 20 Zeichen)
        - Mindestens 1 Grossbuchstabe (A-Z)
        - Mindestens 1 Kleinbuchstabe (a-z)
        - Mindestens 1 Ziffer (0-9)
        - Mindestens 1 Sonderzeichen aus dem definierten Set

    Optionaler Datei-Export: Passwort wird DPAPI-verschluesselt in eine
    Textdatei geschrieben (ConvertFrom-SecureString).
    Nur der Benutzer/Computer der exportiert hat kann die Datei wieder lesen.

.PARAMETER Length
    Laenge des Passworts. Standard: 20. Minimum: 12.

.PARAMETER ExportPath
    Optionaler Pfad fuer die verschluesselte Passwort-Datei.
    Z.B.: C:\System\Passwords\sa_password.txt
    Wenn leer: kein Export.

.OUTPUTS
    [SecureString] - Das generierte Passwort als SecureString.
    (Klartext wird nicht ausgegeben - nur auf expliziten Wunsch via [PSCredential].)

.EXAMPLE
    $pwd = New-sqmRandomSaPassword
    # Gibt SecureString zurueck

.EXAMPLE
    $pwd = New-sqmRandomSaPassword -Length 24 -ExportPath 'C:\System\Passwords\sa.txt'
    # SecureString + DPAPI-Export nach C:\System\Passwords\sa.txt

.EXAMPLE
    # Klartext anzeigen (nur fuer Debugging):
    $pwd = New-sqmRandomSaPassword
    $cred = New-Object PSCredential('sa', $pwd)
    $cred.GetNetworkCredential().Password

.NOTES
    DPAPI-Export: Die Datei kann nur vom selben Windows-Benutzerprofil
    auf demselben Computer entschluesselt werden.
    Fuer produktive Umgebungen: Key Vault oder CyberArk verwenden.
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
