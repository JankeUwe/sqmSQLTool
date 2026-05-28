<#	
	===========================================================================
	 Created with: 	SAPIEN Technologies, Inc., PowerShell Studio 2021 v5.8.183
	 Created on:   	21.04.2026 15:37
	 Created by:   	Janke
	 Organization: 	dtcSoftware
	 Filename:     	sqmSQLTool.psd1
	 -------------------------------------------------------------------------
	 Module Manifest
	-------------------------------------------------------------------------
	 Module Name: sqmSQLTool
	===========================================================================
#>

@{
	# Script module or binary module file associated with this manifest
	RootModule			   = 'sqmSQLTool.psm1'
	
	# Version number of this module.
	ModuleVersion		   = '1.4.0.0'
	
	# ID used to uniquely identify this module
	GUID				   = 'c4b10ba2-aee2-4d8d-ad86-a6e97c346ba6'
	
	# Author of this module
	Author				   = 'Uwe Janke'

	# Company or vendor of this module
	CompanyName		       = 'dtcSoftware'

	# Copyright statement for this module
	Copyright			   = '(c) 2026 Uwe Janke. MIT License.'

	# Description of the functionality provided by this module
	Description		       = 'SQL Server administration toolkit built on dbatools. Provides reporting, health checks, maintenance automation and security auditing for SQL Server environments.'
	
	# KORREKTUR #8: Minimum PS-Version auf 5.1 angehoben
	# (Modul nutzt Generic.List, dbatools, Hashtable-Methoden - alles setzt PS 5.1 voraus)
	PowerShellVersion	   = '5.1'
	
	# Minimum version of the .NET Framework required by this module
	DotNetFrameworkVersion = '4.5'
	
	# Minimum version of the common language runtime (CLR) required by this module
	CLRVersion			   = '4.0'
	
	# Processor architecture (None, X86, Amd64, IA64) required by this module
	ProcessorArchitecture  = 'None'
	
	# Modules that must be imported into the global environment prior to importing this module
	RequiredModules	       = @("dbatools")
	
	# Assemblies that must be loaded prior to importing this module
	RequiredAssemblies	   = @()
	
	# Script files (.ps1) that are run in the caller's environment prior to importing this module
	ScriptsToProcess	   = @()
	
	# Type files (.ps1xml) to be loaded when importing this module
	TypesToProcess		   = @()
	
	# Format files (.ps1xml) to be loaded when importing this module
	FormatsToProcess	   = @()
	
	# Modules to import as nested modules of the module specified in ModuleToProcess
	NestedModules		   = @()
	
	# Explizite Liste aller exportierten Funktionen (kein Wildcard) fuer vollstaendiges IntelliSense
	# in PowerShell ISE und VS Code ohne dass das Modul geladen sein muss.
	FunctionsToExport	   = @(
		'Compare-sqmServerConfiguration',
		'Copy-sqmLogins',
		'Copy-sqmNTFSPermissions',
		'Copy-sqmToCentralPath',
		'Export-sqmDatabaseDocumentation',
		'Find-sqmDatabaseObject',
		'Get-sqmADAccountStatus',
		'Get-sqmAgentJobHistory',
		'Get-sqmAgHealthReport',
		'Get-sqmAutoGrowthReport',
		'Get-sqmBlockingReport',
		'Get-sqmCertificateReport',
		'Get-sqmClusterInfo',
		'Get-sqmConfig',
		'Get-sqmConnectionStats',
		'Get-sqmDatabaseHealth',
		'Get-sqmDeadlockReport',
		'Get-sqmDiskBlockSize',
		'Get-sqmDiskInfoByDriveLetter',
		'Get-sqmDiskSpaceReport',
		'Get-sqmHpuAllowGroup',
		'Get-sqmIndexFragmentation',
		'Get-sqmLinkedServerUsage',
		'Get-sqmLongRunningQueries',
		'Get-sqmMissingIndexes',
		'Get-sqmOperationStatus',
		'Get-sqmOrphanedFiles',
		'Get-sqmPerfCounters',
		'Get-sqmServerHardwareReport',
		'Get-sqmServerSetting',
		'Get-sqmSpnReport',
		'Get-sqmSQLInstanceCheck',
		'Get-sqmSysadminAccounts',
		'Get-sqmTempDbRecommendation',
		'Get-sqmTlsStatus',
		'Get-sqmTsmConfiguration',
		'Get-sqmWaitStatistics',
		'Install-sqmAdModule',
		'Install-sqmCertificate',
		'Install-sqmCertificateToStore',
		'Install-sqmDb2Driver',
		'Install-sqmJdbcDriver',
		'Install-sqmOdbcDriver',
		'Install-sqmOlaMaintenanceSolution',
		'Install-sqmSsrsReportServer',
		'Invoke-sqmAddDatabaseToAG',
		'Invoke-sqmCollationChange',
		'Invoke-sqmDeployScripts',
		'Invoke-sqmExtendedEvents',
		'Invoke-sqmFailover',
		'Invoke-sqmFormatDrive64k',
		'Invoke-sqmInstanceInventory',
		'Invoke-sqmLoginAudit',
		'Invoke-sqmLogShrink',
		'Invoke-sqmMonitoringKey',
		'Invoke-sqmPatchAnalysis',
		'Invoke-sqmPerfBaseline',
		'Invoke-sqmQueryStore',
		'Invoke-sqmRestoreDatabase',
		'Invoke-sqmSaObfuscation',
		'Invoke-sqmSetDatabaseRecoveryMode',
		'Invoke-sqmSetupReport',
		'Invoke-sqmSignModule',
		'Invoke-sqmSplunkConfiguration',
		'Invoke-sqmSqlAlwaysOnAutoseeding',
		'Invoke-sqmSsisConfiguration',
		'Invoke-sqmTsmConfiguration',
		'Invoke-sqmUpdateStatistics',
		'Invoke-sqmUserDatabaseBackup',
		'New-sqmAgentProxy',
		'New-sqmAlwaysOnRepairJob',
		'New-sqmBackupMaintenanceJob',
		'New-sqmCertificateRequest',
		'New-sqmOlaMaintenanceJobs',
		'New-sqmOlaSysDbBackupJob',
		'New-sqmOlaUsrDbBackupJob',
		'New-sqmRandomSaPassword',
		'New-sqmSqlCertificate',
		'Remove-sqmDatabaseFromAG',
		'Repair-sqmAlwaysOnDatabases',
		'Set-sqmBackupExcludePermission',
		'Set-sqmConfig',
		'Set-sqmDatabaseOwner',
		'Set-sqmSqlPolicyState',
		'Set-sqmSqlTlsCertificate',
		'Set-sqmSsrsConfiguration',
		'Set-sqmSsrsHttpsCertificate',
		'Set-sqmTcpPort',
		'Sync-sqmAgNode',
		'Sync-sqmBackupExcludeTable',
		'Test-sqmBackupIntegrity',
		'Test-sqmCostThreshold',
		'Test-sqmDriverInstalled',
		'Test-sqmMaxDop',
		'Test-sqmMaxMemory',
		'Test-sqmModuleUpdate',
		'Test-sqmOlaInstallation',
		'Test-sqmSQLFirewall',
		'Test-sqmSqlInstanceInstalled',
		'Test-sqmSsasDirectoryPermissions',
		'Test-sqmTempDbFileCount',
		'Test-sqmTsmConnection',
		'Uninstall-sqmDb2Driver',
		'Uninstall-sqmJdbcDriver',
		'Uninstall-sqmOdbcDriver',
		'Update-sqmModule'
	)
	
	# KORREKTUR #9: Keine Cmdlets im Modul - explizit leer statt '*'
	CmdletsToExport	       = @()
	
	# KORREKTUR #9: Keine Variablen exportieren - explizit leer statt '*'
	VariablesToExport	   = @()
	
	# KORREKTUR #9: Keine Aliases - explizit leer statt '*'
	AliasesToExport	       = @()
	
	# List of all modules packaged with this module
	ModuleList			   = @()
	
	# List of all files packaged with this module
	FileList			   = @()
	
	# Private data to pass to the module specified in ModuleToProcess.
	PrivateData		       = @{
		PSData = @{
			# Tags applied to this module. These help with module discovery in online galleries.
			Tags = @(
				'SQLServer', 'DBA', 'dbatools', 'Administration',
				'HealthCheck', 'Reporting', 'Maintenance', 'AlwaysOn',
				'Backup', 'Security', 'Automation', 'MSSQL',
				'TLS', 'Certificate', 'Deployment', 'SSRS'
			)

			# A URL to the license for this module.
			LicenseUri = 'https://github.com/JankeUwe/sqmSQLTool/blob/main/LICENSE'

			# A URL to the main website for this project.
			ProjectUri = 'https://github.com/JankeUwe/sqmSQLTool'

			# A URL to an icon representing this module.
			# IconUri = ''

			# ReleaseNotes of this module
			ReleaseNotes = 'v1.4.0 - Get-sqmServerHardwareReport: HTML-Hardware-Konfigurationsbericht mit RAM, CPU, Laufwerken, VM-Erkennung (Hyper-V/VMware/VirtualBox/KVM), Netzwerk, OS und SQL Server Instanzen. Remote-faehig via CIM/WMI. v1.3.0 - TLS/Certificate management: Get-sqmTlsStatus (audit TLS protocols + cert binding), Set-sqmSqlTlsCertificate (bind cert to SQL Server, grant ACL to service account), Install-sqmCertificateToStore (distribute PFX/CER to Windows cert stores locally and remote), Set-sqmSsrsHttpsCertificate (configure SSRS/PBIRS HTTPS via WMI). Deployment: Invoke-sqmDeployScripts (sequential numbered SQL script deployment with backup, transaction wrapper, USE-DB check, WhatIf), Invoke-sqmSignModule (Authenticode code signing for cross-domain deployment). Diagnostics: Get-sqmDiskInfoByDriveLetter (disk info by drive letter with clipboard output). SQL Server 2012-2025 compatibility fix in Get-sqmAgHealthReport.'
		}
	}
}
