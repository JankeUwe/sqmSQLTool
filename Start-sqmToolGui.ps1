<#
.SYNOPSIS
    Starts Show-sqmToolGui with full error logging - invoked elevated by Start-sqmToolGui.cmd.

.DESCRIPTION
    A plain try/catch around Show-sqmToolGui does NOT reliably catch exceptions raised while
    ShowDialog()'s message loop is running (e.g. inside a control event handler) - hosting
    WinForms under powershell.exe, .NET's default unhandled-exception policy for the UI thread
    can terminate the process before the exception ever reaches the calling try/catch, with no
    visible error at all (window flashes briefly, then the process is just gone).

    This sets Application.SetUnhandledExceptionMode + a ThreadException handler so ANY failure -
    synchronous (module import, GUI construction) or asynchronous (inside the message loop) -
    is written to gui-launch.log and shown in a MessageBox instead of failing silently.
#>

$logDir = Join-Path $env:ProgramData 'sqmSQLTool'
$logFile = Join-Path $logDir 'gui-launch.log'
try { if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } } catch { }

function Write-sqmGuiLog
{
    param ([string]$Message)
    try { Add-Content -Path $logFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message" -Encoding UTF8 } catch { }
}

function Show-sqmGuiError
{
    param ([string]$Message)
    Write-sqmGuiLog $Message
    try
    {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show($Message, 'sqmSQLTool GUI', 'OK', 'Error') | Out-Null
    }
    catch { }
}

try
{
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
            param ($senderObj, $e)
            Show-sqmGuiError "Unbehandelte GUI-Ausnahme: $($e.Exception.GetType().FullName): $($e.Exception.Message)`r`n$($e.Exception.StackTrace)"
        })

    Write-sqmGuiLog "Starte sqmSQLTool GUI (PID $PID, PS $($PSVersionTable.PSVersion))..."
    Import-Module sqmSQLTool -ErrorAction Stop
    Show-sqmToolGui
    Write-sqmGuiLog "GUI beendet (normal)."
}
catch
{
    Show-sqmGuiError "sqmSQLTool konnte nicht gestartet werden: $($_.Exception.GetType().FullName): $($_.Exception.Message)`r`n$($_.ScriptStackTrace)`r`n`r`nIst das Modul installiert? Ggf. Install.cmd AllUsers erneut ausfuehren."
}
