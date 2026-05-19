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
	ModuleVersion		   = '1.1.0.0'
	
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
	
	# KORREKTUR #9: Nur Funktionen mit -sqm- exportieren (kein blindes '*')
	# Export-ModuleMember im PSM1 steuert den Export; hier Wildcard auf Muster eingeschraenkt
	FunctionsToExport	   = @('*-sqm*', 'Test-sqmModuleUpdate', 'Update-sqmModule')
	
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
				'Backup', 'Security', 'Automation', 'MSSQL'
			)

			# A URL to the license for this module.
			LicenseUri = 'https://github.com/JankeUwe/sqmSQLTool/blob/main/LICENSE'

			# A URL to the main website for this project.
			ProjectUri = 'https://github.com/JankeUwe/sqmSQLTool'

			# A URL to an icon representing this module.
			# IconUri = ''

			# ReleaseNotes of this module
			ReleaseNotes = 'v1.1.0 - Dynamic backup exclude table: Sync-sqmBackupExcludeTable, Set-sqmBackupExcludePermission, New-sqmBackupMaintenanceJob. Extended Invoke-sqmUserDatabaseBackup and New-sqmOlaUsrDbBackupJob with -UseExcludeTable, -CheckPreferredReplica (AG-aware), mail notification (-MailTo, -MailProfile, -MailOnSuccess), and change history/audit trigger.'
		}
	}
}
