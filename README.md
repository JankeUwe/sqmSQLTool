# sqmSQLTool

**Enterprise SQL Server Administration & AlwaysOn Automation Toolkit**

A comprehensive PowerShell module for SQL Server 2016+ administration, with specialized support for AlwaysOn Availability Groups, performance reporting, and security auditing.

**Latest Release:** [v1.9.80.0](https://github.com/JankeUwe/sqmSQLTool/releases/tag/v1.9.80.0) | **Functions:** 163 | **Documentation:** [Full Reference](https://www.powershelldba.de/sqmsqltool/commands-en/)

---

## 🕐 Recent Highlights (v1.9.60 - v1.9.80)

- `New-sqmAgentCommandJob` - generic SQL Agent job/step builder that wraps any sqmSQLTool function via a Clixml-serialized parameter splat
- `Export-sqmDatabaseLogins` / `Import-sqmDatabaseLogins` / `Sync-sqmDatabaseLogins` - database-level login export, import, and sync
- AlwaysOn rejoin fixes: correct recovery model on rejoin, automatic backup lookup by database name
- `Get-sqmLoginSettings`, `Get-sqmAlwaysOnFailoverHistory`, `Get-sqmTlsStatus`, `Invoke-sqmInstanceInventory` and 33 other report functions now write automatic TXT/CSV/HTML output to their own subfolder by default
- `Get-sqmSpnReport` no longer flags AG partner-replica SPNs or duplicate listener SPN rows as errors

## 🎯 Execution Plan Analysis & Login Sync

### Execution Plan Analysis
`Get-sqmPlanInsights` parses ShowPlan XML (.sqlplan/.xml) and reports cardinality-estimate mismatches, SARGability violations, parameter-sniffing risk, tempdb spills, and missing-index suggestions — with runtime-evidence-based severity scoring instead of relying on optimizer cost estimates:

```powershell
# Find the most expensive statements in the plan cache and export their plans
$top = Get-sqmPlanCacheReport -SqlInstance "SQL01" -SortBy CPU -Top 5 -ExportPlans

# Offline analysis of a saved plan
Get-sqmPlanInsights -Path $top[0].PlanFile

# With live Query Store telemetry and a JSON bundle for the visualizer
Get-sqmPlanInsights -Path ".\slow-query.sqlplan" -ServerInstance "SQL01" `
    -Database "AppDB" -InspectDatabase -OutFile ".\plan.json"
```

Pair it with the offline, self-contained **[Plan Visualizer](Tools/PlanVisualizer/plan_visualizer_V4.html)** (`Tools\PlanVisualizer\plan_visualizer_V4.html`) — drop the JSON bundle in for an interactive diagram with the same findings. No network calls, nothing leaves your machine.

### Enterprise AlwaysOn Login Synchronization
Automatically synchronize SQL logins from primary to secondary replicas in AlwaysOn Availability Groups:

```powershell
# Install the standard job on EVERY replica (daily 2:00 AM, only the primary works)
Install-sqmStandardJob -Name AgLoginSync -AvailabilityGroupName "ProdAG"

# All standard jobs with their defaults
Install-sqmStandardJob -List

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
# Output: 163 functions
```

### Updates
On the first sqmSQLTool command of a session (at most once every 24 hours) the module checks
its install source (PSGallery, UNC share or local folder) for a newer version and offers to
install it: Yes / No (ask again later) / Skip this version. SQL Agent jobs, scheduled tasks and
`-NonInteractive` sessions are never prompted.

```powershell
Update-sqmModule                      # check and update manually
Set-sqmConfig -UpdateMode Prompt      # default: offer newer versions
Set-sqmConfig -UpdateMode Auto        # install without asking (also in Agent jobs)
Set-sqmConfig -UpdateMode Off         # no check
```

---

## 🚀 Key Features

### AlwaysOn Availability Groups
- `Sync-sqmLoginsToAlwaysOn` - Automated login synchronization
- `Install-sqmStandardJob` - Standard Agent jobs (AgLoginSync, AgLoginCompare) in one call
- `New-sqmAutoLoginSyncJob` - Shortcut for `Install-sqmStandardJob -Name AgLoginSync`
- `Get-sqmDistributedAgHealth` - Distributed AG status
- `Get-sqmSpnReport` - SPN validation including listeners
- `Complete-sqmListenerMigration` - Listener migration workflow

### Performance & Health
- `Invoke-sqmHealthReport` - All checks in one call: one HTML report with prioritized findings, linked detail reports, optional ZIP
- `Get-sqmPlanCacheReport` - Top N plan cache statements by CPU, duration, reads, grants, spills, with .sqlplan export
- `Get-sqmPlanInsights` - Execution plan analysis: CE mismatches, SARGability, spills, missing indexes
- `Get-sqmIndexUsageReport` - Unused, duplicate and overlapping indexes, heaps (read-only, DROP script commented out)
- `Get-sqmFileLatencyReport` - Read/write latency per database file, cumulative or live sample
- `Get-sqmWaitStatistics` - SQL Server wait statistics
- `Get-sqmDiskSpaceReport` - Disk utilization and growth trends
- `Test-sqmBackupStatus` - Backup control: Full/Diff/Log age per database against thresholds, honours sqm_BackupExclude, flags databases created after the last backup run
- `Get-sqmDatabaseRestoreHistory` - Last restore date per database, flags never-restored databases
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
Complete documentation with examples for all 163 functions:
- **HTML Reference**: https://www.powershelldba.de/sqmsqltool/commands-en/
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
A: Yes. Run `Install-sqmStandardJob -Name AgLoginSync` on every replica. It creates a SQL Agent job that runs daily at 2:00 AM; on a secondary the step ends without doing anything, so after a failover the new primary takes over. The job only adds missing logins (`-Force:$false`), it never drops and recreates existing ones.

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
