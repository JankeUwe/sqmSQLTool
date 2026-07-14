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
	ModuleVersion		   = '1.9.14.0'
	
	# ID used to uniquely identify this module
	GUID				   = 'c4b10ba2-aee2-4d8d-ad86-a6e97c346ba6'
	
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
	
	# FunctionsToExport: Explizite Liste ALLER public Funktionen
	# Diese Liste steuert den Export vollstaendig — Export-ModuleMember wird in .psm1 NICHT aufgerufen.
	# Grund: Export-ModuleMember loest eine PowerShell WARNING aus wenn Funktionsnamen Bindestriche
	# enthalten (Verb-Noun Pattern). Die WARNING ist harmlos aber verunsichert Anwender.
	# Loesung: Nur .psd1 steuert den Export. Private Funktionen stehen nicht in dieser Liste
	# und bleiben damit automatisch privat.
	FunctionsToExport	   = @(
		'Add-sqmDatabaseToAG',
		'Add-sqmDatabaseToDistributedAg',
		'Compare-sqmAlwaysOnLogins',
		'Compare-sqmAlwaysOnRoles',
		'Compare-sqmServerConfiguration',
		'Complete-sqmListenerMigration',
		'Copy-sqmLogins',
		'Copy-sqmNTFSPermissions',
		'Copy-sqmToCentralPath',
		'Enable-sqmMonitoringAccess',
		'Enable-sqmServiceBroker',
		'Export-sqmAlwaysOnConfiguration',
		'Export-sqmDatabaseDocumentation',
		'Export-sqmServerConfiguration',
		'Find-sqmADUser',
		'Find-sqmDatabaseObject',
		'Get-sqmADAccountStatus',
		'Get-sqmServersFromOU',
		'Get-sqmADGroupMembers',
		'Get-sqmADGroupMembersRecursive',
		'Get-sqmADMemberGroups',
		'Get-sqmAgentJobHistory',
		'Get-sqmAgentJobScheduleReport',
		'Get-sqmAlwaysOnFailoverHistory',
		'Get-sqmAlwaysOnHealthReport',
		'Get-sqmAutoGrowthReport',
		'Get-sqmBlockingReport',
		'Get-sqmCertificateReport',
		'Get-sqmClusterInfo',
		'Get-sqmConfig',
		'Get-sqmConnectionStats',
		'Get-sqmDatabaseHealth',
		'Get-sqmDeadlockReport',
		'Get-sqmDistributedAgHealth',
		'Get-sqmDiskBlockSize',
		'Get-sqmDiskInfoByDriveLetter',
		'Get-sqmDiskPartitionMap',
		'Get-sqmDiskSpaceReport',
		'Get-sqmHpuAllowGroup',
		'Get-sqmIndexFragmentation',
		'Get-sqmLinkedServerUsage',
		'Get-sqmLoginSettings',
		'Get-sqmLongRunningQueries',
		'Get-sqmMissingIndexes',
		'Get-sqmOperationStatus',
		'Get-sqmOrphanedFiles',
		'Get-sqmPerfCounters',
		'Get-sqmServerHardwareReport',
		'Get-sqmSaLogin',
		'Get-sqmServerSetting',
		'Get-sqmServerUtilization',
		'Get-sqmSpnReport',
		'Get-sqmSQLInstanceCheck',
		'Get-sqmServiceBrokerHealth',
		'Get-sqmSysadminAccounts',
		'Grant-sqmTemporarySysadmin',
		'Invoke-sqmTempSysadminAction',
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
		'Invoke-sqmCollationChange',
		'Invoke-sqmConfigRollback',
		'Invoke-sqmDeployScripts',
		'Invoke-sqmDistributedFailover',
		'Invoke-sqmExtendedEvents',
		'Invoke-sqmFailover',
		'Invoke-sqmFormatDrive64k',
		'Invoke-sqmInstanceInventory',
		'Invoke-sqmLogging',
		'Invoke-sqmLoginAudit',
		'Invoke-sqmLogShrink',
		'Invoke-sqmMonitoringKey',
		'Invoke-sqmNtfsSetup',
		'Invoke-sqmPatchAnalysis',
		'Invoke-sqmPerfBaseline',
		'Invoke-sqmQueryStore',
		'Invoke-sqmRestoreDatabase',
		'Invoke-sqmSaObfuscation',
		'Invoke-sqmAlwaysOnSetup',
		'Invoke-sqmServiceBrokerAlwaysOn',
		'Invoke-sqmSetDatabaseRecoveryMode',
		'Invoke-sqmSetupReport',
		'Invoke-sqmSignModule',
		'Invoke-sqmSplunkConfiguration',
		'Invoke-sqmSqlAlwaysOnAutoseeding',
		'Invoke-sqmSsisConfiguration',
		'Invoke-sqmTsmConfiguration',
		'Invoke-sqmUpdateStatistics',
		'Invoke-sqmUserDatabaseBackup',
		'Move-sqmAlwaysOnListener',
		'New-sqmAgentProxy',
		'New-sqmAlwaysOnRepairJob',
		'New-sqmAvailabilityGroup',
		'New-sqmBackupMaintenanceJob',
		'New-sqmCertificateRequest',
		'New-sqmDistributedAvailabilityGroup',
		'New-sqmOlaMaintenanceJobs',
		'New-sqmOlaSysDbBackupJob',
		'New-sqmOlaUsrDbBackupJob',
		'New-sqmAutoLoginSyncJob',
		'New-sqmRandomSaPassword',
		'New-sqmSetupReport',
		'New-sqmSqlCertificate',
		'Invoke-sqmListenerMigrationPrep',
		'Remove-sqmAdOrphanLogin',
		'Remove-sqmDatabaseFromAG',
		'Register-sqmBackupExcludeTrigger',
		'Repair-sqmAlwaysOnDatabases',
		'Set-sqmBackupExcludePermission',
		'Set-sqmConfig',
		'Set-sqmDatabaseOwner',
		'Set-sqmMaxDop',
		'Set-sqmMaxMemory',
		'Set-sqmSqlPolicyState',
		'Set-sqmSqlTlsCertificate',
		'Set-sqmSsasDeploymentMode',
		'Set-sqmSsrsConfiguration',
		'Set-sqmSsrsHttpsCertificate',
		'Set-sqmTcpPort',
		'Show-sqmBackupExcludeForm',
		'Show-sqmToolGui',
		'Sync-sqmAgNode',
		'Sync-sqmBackupExcludeTable',
		'Sync-sqmLoginsToAlwaysOn',
		'Test-sqmBackupIntegrity',
		'Test-sqmCostThreshold',
		'Test-sqmDistributedAgReadiness',
		'Test-sqmDriverInstalled',
		'Test-sqmMaxDop',
		'Test-sqmMaxMemory',
		'Test-sqmOlaInstallation',
		'Test-sqmSQLFirewall',
		'Test-sqmSqlInstanceInstalled',
		'Test-sqmSsasDirectoryPermissions',
		'Test-sqmSSISPackageCompatibility',
		'Test-sqmTempDbFileCount',
		'Test-sqmTsmConnection',
		'Uninstall-sqmDb2Driver',
		'Uninstall-sqmJdbcDriver',
		'Uninstall-sqmOdbcDriver',
		'Write-sqmSetupEvent'
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
			Tags = @('SQLServer', 'DBA', 'Automation')

			# A URL to the license for this module.
			LicenseUri = 'https://github.com/JankeUwe/sqmSQLTool/blob/main/LICENSE'

			# A URL to the main website for this project.
			ProjectUri = 'https://github.com/JankeUwe/sqmSQLTool'

			# A URL to an icon representing this module.
			# IconUri = ''

			# ReleaseNotes of this module
			ReleaseNotes = 'See CHANGELOG.md and GitHub: https://github.com/JankeUwe/sqmSQLTool/releases/tag/v1.9.9.1'

			# External module dependencies
			ExternalModuleDependencies = @('dbatools')
		}
	}
}


