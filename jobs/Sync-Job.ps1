$ErrorActionPreference = 'Stop'

Import-Module sqmSQLTool -Force

Sync-sqmLoginsToAlwaysOn -Force:$false -BackupRetentionDays 0 -NoReport -Confirm:$false -ErrorAction Stop

exit 0
