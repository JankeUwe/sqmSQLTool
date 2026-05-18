param([string]$Source = $PSScriptRoot, [string]$Destination = "$env:ProgramFiles\WindowsPowerShell\Modules\sqmSQLTool")
robocopy $Source $Destination /E /PURGE /NJH /NJS /NDL