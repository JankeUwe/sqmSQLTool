$ErrorActionPreference = 'Stop'
Import-Module sqmSQLTool -Force

Repair-sqmAlwaysOnDatabases -Confirm:$false -ErrorAction Stop

exit 0
