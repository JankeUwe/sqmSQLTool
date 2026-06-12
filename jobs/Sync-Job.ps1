$ErrorActionPreference = 'Stop'
Import-Module sqmSQLTool -Force

Sync-sqmLoginsToAlwaysOn -BackupRetentionDays 0 -Confirm:$false -ErrorAction Stop

exit 0
