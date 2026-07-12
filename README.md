# sqmSQLTool

**Enterprise SQL Server Administration & AlwaysOn Automation Toolkit**

A comprehensive PowerShell module for SQL Server 2016+ administration, with specialized support for AlwaysOn Availability Groups, performance reporting, and security auditing.

**Latest Release:** [v1.9.9.0](https://github.com/JankeUwe/sqmSQLTool/releases/tag/v1.9.9.0) | **Functions:** 144 | **Documentation:** [Full Reference](https://www.powershelldba.de/tools/befehls-referenz)

---

## 🎯 What''s New in v1.9.9.0

### Enterprise AlwaysOn Login Synchronization
Automatically synchronize SQL logins from primary to secondary replicas in AlwaysOn Availability Groups:

```powershell
# Create daily scheduled job (2:00 AM)
New-sqmAutoLoginSyncJob -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG"

# Run sync immediately with backup
Sync-sqmLoginsToAlwaysOn -SqlInstance "SQL01" -AvailabilityGroupName "ProdAG" `
    -Force -BackupLogins
```

### Enterprise Security Features
- **-Force Mode**: Update existing logins (password changes)
- **SafeForceMode**: Auto-exclude sa, SQL Agent Account, system logins
- **-ForceIncludeOnly**: Whitelist specific logins for updates
- **Backup-Logins**: Create rollback scripts before applying changes

### AlwaysOn Improvements
- **Listener SPN Checking**: Get-sqmSpnReport now validates AlwaysOn listener SPNs
- **UPN Support**: Fixed service account handling for UPN format (user@domain.net)
- **Smart AG Detection**: Auto-detect primary/secondary replicas with warnings for multiple AGs

---

## 📦 Installation

### From GitHub
```powershell
# Clone repository
git clone https://github.com/JankeUwe/sqmSQLTool.git

# Import module
Import-Module ./sqmSQLTool/sqmSQLTool.psd1 -Force
```

### Verify Installation
```powershell
Get-Command -Module sqmSQLTool | Measure-Object
# Output: 124 functions
```

---

## 🚀 Key Features

### AlwaysOn Availability Groups
- `Sync-sqmLoginsToAlwaysOn` - Automated login synchronization
- `New-sqmAutoLoginSyncJob` - Scheduled job creation
- `Get-sqmDistributedAgHealth` - Distributed AG status
- `Get-sqmSpnReport` - SPN validation including listeners
- `Complete-sqmListenerMigration` - Listener migration workflow

### Performance & Health
- `Get-sqmWaitStatistics` - SQL Server wait statistics
- `Get-sqmDiskSpaceReport` - Disk utilization and growth trends
- `Get-sqmMissingIndexes` - Index recommendations with CREATE statements
- `Get-sqmAutoGrowthReport` - Database autogrowth tracking
- `Get-sqmIndexFragmentation` - Index fragmentation analysis

### Security & Compliance
- `Copy-sqmLogins` - Transfer logins with password hash preservation
- `Get-sqmSysadminAccounts` - Enumerate sysadmin accounts
- `Get-sqmADGroupMembers` - Validate AD group memberships
- `Get-sqmTlsStatus` - SQL Server TLS/SSL configuration
- `Invoke-sqmLoginAudit` - Login activity tracking

### Configuration & Deployment
- `Export-sqmServerConfiguration` - Full instance configuration export
- `Compare-sqmServerConfiguration` - Instance comparison
- `Export-sqmAlwaysOnConfiguration` - AG configuration export
- `Export-sqmDatabaseDocumentation` - Database schema documentation

---

## 📚 Documentation

### Full Command Reference
Complete documentation with examples for all 143 functions:
- **HTML Reference**: https://www.powershelldba.de/tools/befehls-referenz
- **GitHub Releases**: https://github.com/JankeUwe/sqmSQLTool/releases

---

## 🔧 Requirements

- **SQL Server**: 2016 or later
- **PowerShell**: 5.1 or 7.x
- **dbatools**: Latest version (installed as dependency)
- **Operating System**: Windows Server 2016+
- **Permissions**: sysadmin on SQL Server instances

---

## ❓ FAQ

**Q: Can I use sqmSQLTool with SQL Server 2012 or 2014?**  
A: No. Minimum requirement is SQL Server 2016. Features like Distributed AGs require SQL Server 2019+.

**Q: Do I need sysadmin rights for all functions?**  
A: Most functions require sysadmin. Some read-only functions (e.g., `Get-sqmDiskSpaceReport`) work with lower roles, but login synchronization and configuration export require sysadmin.

**Q: How do I import the module in PowerShell 5.1 vs 7.x?**  
A: Same command works for both: `Import-Module ./sqmSQLTool/sqmSQLTool.psd1`. Module is compatible with .NET Framework 4.8 (PS 5.1) and .NET 6+ (PS 7.x).

**Q: What if `Sync-sqmLoginsToAlwaysOn` fails with "Login already exists"?**  
A: Use `-Force` flag to update existing logins. Use `-SafeForceMode` to auto-exclude system accounts. Run with `-WhatIf` first to preview changes.

**Q: Can I schedule login sync across multiple AG instances?**  
A: Yes. Use `New-sqmAutoLoginSyncJob` on the primary replica. It creates a SQL Agent job that runs daily at 2:00 AM.

**Q: How do I export AlwaysOn configuration for documentation?**  
A: Use `Export-sqmAlwaysOnConfiguration -SqlInstance "SQL01" -OutputPath "C:\Exports"`. Generates HTML + CSV with replica status, listeners, and database sync state.

**Q: Does the module support Azure SQL Managed Instance?**  
A: Limited support. AlwaysOn features don't apply. Use security/login functions (`Get-sqmSysadminAccounts`, `Get-sqmTlsStatus`) with caution due to API differences.

---

## 📄 License

MIT License - See LICENSE file for details

---

## 👤 Author

**Uwe Janke** | Senior IT Specialist | SQL Server & PowerShell Automation

- GitHub: [@JankeUwe](https://github.com/JankeUwe)
- Website: https://www.powershelldba.de
