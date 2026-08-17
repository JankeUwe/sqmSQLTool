<#
.SYNOPSIS
    Sendet eine Netzwerk-Meldung an aktive interaktive Sitzungen auf einem Windows-Host.

.DESCRIPTION
    Ruft WTSSendMessage aus wtsapi32.dll direkt per P/Invoke auf, statt msg.exe als externes
    Programm aufzurufen. Grund: msg.exe (Terminal-Services-Kommandozeilentool) ist Teil der
    Remote-Desktop-Services-Admintools und auf Windows-Client-SKUs (getestet: Windows 11 Home)
    haeufig NICHT vorhanden - wtsapi32.dll dagegen ist Bestandteil jeder Windows-Installation
    (Server wie Client) und wird von msg.exe selbst nur duenn umschlossen. Verifiziert per
    Livetest DEV03 (lokal, Session 'Console') und DEV03 -> DEV01 (cross-machine, Workgroup ohne
    Domaene) - beide WTSSendMessage-Aufrufe lieferten TRUE.

    Sendet an alle Sitzungen mit WTS-Status "Active" (0) auf dem Zielhost. Sitzungen ohne
    Benutzer (z.B. Session 0 "Services") oder nur "Connected" ohne aktiven Desktop werden nicht
    angeschrieben.

.PARAMETER ComputerName
    Zielhost, an den die Meldung gesendet werden soll.

.PARAMETER Title
    Titel des Meldungsfensters.

.PARAMETER Message
    Nachrichtentext.

.PARAMETER TimeoutSeconds
    Anzeigedauer beim Empfaenger, bevor das Fenster automatisch verschwindet. 0 = kein Timeout.

.NOTES
    Erfordert auf dem Zielhost Zugriffsrechte fuer Remote-Terminaldienste-Abfragen (i.d.R.
    lokale Administratorrechte dort) sowie Netzwerkerreichbarkeit (RPC). Gibt KEINE Exception
    bei Erreichbarkeits-/Rechteproblemen - der Aufrufer wertet WasDelivered/Error aus.
#>
function Send-sqmWtsMessage
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$ComputerName,
		[Parameter(Mandatory = $false)]
		[string]$Title = 'sqmSQLTool',
		[Parameter(Mandatory = $true)]
		[string]$Message,
		[Parameter(Mandatory = $false)]
		[int]$TimeoutSeconds = 15
	)

	if (-not ('sqmSQLTool.Native.Wts' -as [type]))
	{
		Add-Type -Namespace sqmSQLTool.Native -Name Wts -MemberDefinition @'
[DllImport("wtsapi32.dll", SetLastError = true)]
public static extern IntPtr WTSOpenServer(string pServerName);

[DllImport("wtsapi32.dll")]
public static extern void WTSCloseServer(IntPtr hServer);

[DllImport("wtsapi32.dll", SetLastError = true)]
public static extern bool WTSEnumerateSessions(IntPtr hServer, int Reserved, int Version, out IntPtr ppSessionInfo, out int pCount);

[DllImport("wtsapi32.dll")]
public static extern void WTSFreeMemory(IntPtr pMemory);

[DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool WTSSendMessage(IntPtr hServer, int SessionId, string pTitle, int TitleLength, string pMessage, int MessageLength, int Style, int Timeout, out int pResponse, bool bWait);
'@
	}

	# WTS_SESSION_INFO: { int SessionId; IntPtr pWinStationName; int State } - 24 Byte auf x64
	# (4 Byte SessionId + 4 Byte Padding + 8 Byte Pointer + 4 Byte State + 4 Byte Padding).
	$sessionInfoSize = 24
	$wtsActive = 0

	$hServer = [IntPtr]::Zero
	$pSessionInfo = [IntPtr]::Zero
	$sentToSessions = [System.Collections.Generic.List[int]]::new()
	$errorMessage = $null

	try
	{
		$hServer = [sqmSQLTool.Native.Wts]::WTSOpenServer($ComputerName)
		if ($hServer -eq [IntPtr]::Zero)
		{
			$errorMessage = "WTSOpenServer('$ComputerName') lieferte ein Null-Handle."
		}
		else
		{
			[int]$sessionCount = 0
			$enumOk = [sqmSQLTool.Native.Wts]::WTSEnumerateSessions($hServer, 0, 1, [ref]$pSessionInfo, [ref]$sessionCount)
			if (-not $enumOk)
			{
				$errorMessage = "WTSEnumerateSessions auf '$ComputerName' fehlgeschlagen (Win32Error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
			}
			else
			{
				for ($i = 0; $i -lt $sessionCount; $i++)
				{
					$entryAddr = [IntPtr]::Add($pSessionInfo, $i * $sessionInfoSize)
					$sessionId = [System.Runtime.InteropServices.Marshal]::ReadInt32($entryAddr, 0)
					$state = [System.Runtime.InteropServices.Marshal]::ReadInt32($entryAddr, 16)

					if ($state -ne $wtsActive) { continue }

					[int]$response = 0
					$sendOk = [sqmSQLTool.Native.Wts]::WTSSendMessage($hServer, $sessionId, $Title, $Title.Length, $Message, $Message.Length, 0, $TimeoutSeconds, [ref]$response, $false)
					if ($sendOk) { $sentToSessions.Add($sessionId) }
				}

				if ($sentToSessions.Count -eq 0)
				{
					$errorMessage = "Keine aktive interaktive Sitzung auf '$ComputerName' gefunden."
				}
			}
		}
	}
	catch
	{
		$errorMessage = "Ausnahme beim Senden an '$ComputerName': $($_.Exception.Message)"
	}
	finally
	{
		if ($pSessionInfo -ne [IntPtr]::Zero) { [sqmSQLTool.Native.Wts]::WTSFreeMemory($pSessionInfo) }
		if ($hServer -ne [IntPtr]::Zero) { [sqmSQLTool.Native.Wts]::WTSCloseServer($hServer) }
	}

	[PSCustomObject]@{
		ComputerName  = $ComputerName
		WasDelivered  = ($sentToSessions.Count -gt 0)
		SessionIds    = $sentToSessions
		Error		  = $errorMessage
	}
}
