<#
.SYNOPSIS
    Prueft, ob die aktuelle Sitzung eine Rueckfrage an den Benutzer beantworten kann.

.DESCRIPTION
    Liefert $false, wenn der Prozess nicht interaktiv laeuft (Dienst, SQL-Agent-Job,
    geplanter Task) oder mit -NonInteractive gestartet wurde. Ein Read-Host haengt dort
    entweder endlos oder bricht mit einem Fehler ab - Funktionen, die nachfragen wollen,
    muessen in dem Fall stattdessen einen eindeutigen Fehler mit Handlungsanweisung werfen.
    Als eigene Funktion, damit Unit-Tests beide Pfade gezielt ansteuern koennen.
#>
function Test-sqmInteractiveSession
{
	[CmdletBinding()]
	[OutputType([bool])]
	param ()

	if (-not [Environment]::UserInteractive) { return $false }

	# -NonInteractive darf abgekuerzt werden (-noni, -NonI ...), -match ist case-insensitiv
	$nonInteractive = [Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^[-/]noni' }
	return (-not $nonInteractive)
}
