<#
.SYNOPSIS
	Creates a SQL Agent job that backs up user databases one at a time via Ola Hallengren's
	DatabaseBackup, driven by a single generic T-SQL procedure in master.

.DESCRIPTION
	Creates a SQL Agent job with ONE Transact-SQL step (subsystem TransactSql, no PowerShell
	anywhere) that calls the generic procedure master.dbo.sqm_BackupUserDatabases.

	The procedure contains no hard-coded values. Everything that differs between backup types,
	instances or jobs is a parameter, and the job step passes those values in plain text, so the
	whole configuration is visible - and editable - directly in the job step:

	    EXEC master.dbo.[sqm_BackupUserDatabases]
	         @BackupType               = N'FULL',
	         @Directory                = N'D:\Backup\Usr-db',
	         @CleanupTime              = 672,
	         @UseExcludeTable          = 1,
	         @SyncExcludeTable         = 1,
	         @IncludeSystemDatabases   = 0,
	         @Verify                   = 'Y',
	         @Compress                 = 'Y',
	         @Checksum                 = 'Y',
	         @OverrideBackupPreference = 'Y',
	         @LogToTable               = 'Y',
	         @MailTo                   = NULL,
	         @MailProfile              = N'Default',
	         @MailOnSuccess            = 0;

	Because it is fully parameterised, ONE procedure serves every backup type and every job on the
	instance - FULL, DIFF and LOG jobs all call the same one. It is dropped and recreated whenever
	this function runs, so -Update refreshes the backup logic itself and not just the job.

	What the procedure does:
	  - With @UseExcludeTable = 1 and @SyncExcludeTable = 1 it first creates master.dbo.
	    sqm_BackupExclude if missing and reconciles it with sys.databases (new databases are added
	    with IsActive=1, vanished ones flagged IsOrphaned=1, returning ones un-flagged).
	  - It then cursors over the candidate databases and calls Ola Hallengren's
	    master.dbo.DatabaseBackup once per database, skipping any database marked IsActive=0 AND
	    IsOrphaned=0 in the exclude table.
	  - Each call sits in its own TRY/CATCH, so one failing database is logged and the loop
	    continues; the step fails only at the end, once at least one database actually failed.

	Earlier versions ran this through the PowerShell subsystem, which reproducibly hung on real
	instances: the job started, the first step never returned, so the backup step never ran at all
	- "job starts, no backup, never comes back" - while the exact same command text pasted into an
	interactive PowerShell console always completed fine. As plain T-SQL the job also no longer
	requires the sqmSQLTool module to be installed on the SQL Server itself.

	Requires Ola Hallengren's Maintenance Solution (master.dbo.DatabaseBackup) on the instance;
	install it with Install-sqmOlaMaintenanceSolution if missing.

	Default schedule per backup type (applied to -ScheduleDays/-ScheduleTime/-ScheduleIntervalMinutes
	whenever the respective parameter is not explicitly specified):
	    FULL — every day (@('EveryDay')) at 20:15, once
	    DIFF — Monday-Saturday (@('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')) at 20:00, once
	    LOG  — every day (@('EveryDay')), starting 00:00, every 15 minutes

	Default cleanup retention per backup type (applied via -CleanupTime unless overridden, skipped
	entirely with -NoCleanup): FULL 4 weeks ('4w'), DIFF 2 weeks ('2w'), LOG 48 hours ('48h'). The
	value is converted to hours and passed to Ola's own @CleanupTime, which deletes old backup
	files of the same type in the target directory after each run.

.PARAMETER SqlInstance
	SQL Server instance. Default: current computer name ($env:COMPUTERNAME).

.PARAMETER SqlCredential
	PSCredential for the SQL connection.

.PARAMETER JobName
	Name of the SQL Agent job to create. When not specified, the name is read from the
	module configuration depending on -BackupType (Set-sqmConfig -BackupMaintenanceJobNameFull/
	-Diff/-Log); if that isn't configured either, defaults to 'sqm-BackupMaintenance-<BackupType>'.

.PARAMETER BackupType
	Backup type: 'FULL', 'DIFF', or 'LOG'. Default: 'FULL'.

.PARAMETER BackupPath
	Backup target directory, passed to the job step as @Directory. When not specified, the
	instance's configured BackupDirectory plus '\Usr-db' is resolved at job-creation time and
	baked into the step, where it stays visible and editable.

.PARAMETER ScheduleTime
	Start time of the schedule in format 'HH:mm'. When not specified, defaults depend on
	BackupType: '20:15' for FULL, '00:00' for LOG, '20:00' for DIFF (see description).

.PARAMETER ScheduleDays
	Days of the week for the schedule. Valid values: 'Monday'..'Sunday', 'Weekdays', 'Weekend',
	'EveryDay'. When not specified, defaults depend on BackupType (see description).

.PARAMETER ScheduleIntervalMinutes
	Repeat interval within a day in minutes (e.g. 15 = every 15 minutes). 0 = run once at
	ScheduleTime. When not specified, defaults to 15 for -BackupType LOG and 0 (once) for
	FULL/DIFF (see description).

.PARAMETER JobCategory
	SQL Agent job category. Default: 'Database Maintenance'.

.PARAMETER UseExcludeTable
	When set, the job step passes @UseExcludeTable = 1, so master.dbo.sqm_BackupExclude is
	reconciled with sys.databases at the start of the run and every database marked IsActive=0
	AND IsOrphaned=0 is skipped.

.PARAMETER CheckPreferredReplica
	When set, the job step passes @OverrideBackupPreference = 'N', so Ola honours the Availability
	Group backup preference and only backs up where this replica is the preferred one. Without it,
	'Y' is passed and databases are backed up regardless of the preference.

.PARAMETER IncludeSystemDatabases
	When set, the job step passes @IncludeSystemDatabases = 1, so master, model and msdb are
	included in both the exclude-table sync and the backup run.

.PARAMETER MailTo
	Recipient email address, passed to the job step as @MailTo. The procedure sends a report via
	msdb.dbo.sp_send_dbmail after the run (on failures, or always with -MailOnSuccess).

.PARAMETER MailProfile
	SQL Server Database Mail profile name, passed to the job step as @MailProfile.
	Default: 'Default'.

.PARAMETER MailOnSuccess
	When set, the job step passes @MailOnSuccess = 1, so a report mail is also sent on full
	success and not only on failures.

.PARAMETER CleanupTime
	Retention period for old backup files, e.g. '48h', '7d', '4w', '1m'. Converted to hours and
	passed to the job step as @CleanupTime for Ola's own cleanup. When not specified, defaults
	depend on BackupType (see description). Use -NoCleanup to disable cleanup entirely.

.PARAMETER NoCleanup
	When set, the job step passes @CleanupTime = NULL, so old backup files are never removed by
	this job. Ignored if -CleanupTime is also specified explicitly.

.PARAMETER OperatorName
	SQL Agent operator name for failure email notification on the job level.

.PARAMETER Update
	When set, replaces an existing job with the same name.

.PARAMETER EnableException
	Throw exceptions immediately instead of returning error objects.

.PARAMETER WhatIf
	Shows what would happen without making changes.

.PARAMETER Confirm
	Request confirmation before creating the job.

.EXAMPLE
	# Daily FULL backup, default schedule: every day at 20:15
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType FULL `
	    -UseExcludeTable -CheckPreferredReplica `
	    -MailTo "dba@company.com" -MailProfile "DBA-Mail"

.EXAMPLE
	# Daily DIFF backup with exclude table
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType DIFF `
	    -UseExcludeTable -ScheduleTime "22:00"

.EXAMPLE
	# LOG backup, default schedule: every day, every 15 minutes starting 00:00,
	# default cleanup: .trn files older than 48h are removed after each run
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType LOG -UseExcludeTable

.EXAMPLE
	# LOG backup with custom retention and no automatic cleanup
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType LOG -CleanupTime "24h"
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType LOG -NoCleanup

.EXAMPLE
	# Replace existing job
	New-sqmBackupMaintenanceJob -SqlInstance "SQL01" -BackupType FULL -Update

.NOTES
	Prerequisites: dbatools, Invoke-sqmLogging, and Ola Hallengren's Maintenance Solution
	(master.dbo.DatabaseBackup) on the target instance.
	The job step is plain T-SQL, so the job itself does not need sqmSQLTool on the SQL Server.
#>
function New-sqmBackupMaintenanceJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,
		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,
		[Parameter(Mandatory = $false)]
		[string]$JobName,
		[Parameter(Mandatory = $false)]
		[ValidateSet('FULL', 'DIFF', 'LOG')]
		[string]$BackupType = 'FULL',
		[Parameter(Mandatory = $false)]
		[string]$BackupPath,
		[Parameter(Mandatory = $false)]
		[ValidatePattern('^\d{2}:\d{2}$')]
		[string]$ScheduleTime = '20:00',
		[Parameter(Mandatory = $false)]
		[ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday', 'Weekdays', 'Weekend', 'EveryDay')]
		[string[]]$ScheduleDays,
		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 1440)]
		[int]$ScheduleIntervalMinutes = 0,
		[Parameter(Mandatory = $false)]
		[string]$JobCategory = 'Database Maintenance',
		[Parameter(Mandatory = $false)]
		[switch]$UseExcludeTable,
		[Parameter(Mandatory = $false)]
		[switch]$CheckPreferredReplica,
		[Parameter(Mandatory = $false)]
		[switch]$IncludeSystemDatabases,
		[Parameter(Mandatory = $false)]
		[string]$MailTo,
		[Parameter(Mandatory = $false)]
		[string]$MailProfile = 'Default',
		[Parameter(Mandatory = $false)]
		[switch]$MailOnSuccess,
		[Parameter(Mandatory = $false)]
		[ValidatePattern('^\d+[hdwm]$')]
		[string]$CleanupTime,
		[Parameter(Mandatory = $false)]
		[switch]$NoCleanup,
		[Parameter(Mandatory = $false)]
		[string]$OperatorName,
		[Parameter(Mandatory = $false)]
		[switch]$Update,
		[Parameter(Mandatory = $false)]
		[switch]$SkipAlwaysOnPropagation,
		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	begin
	{
		$functionName = $MyInvocation.MyCommand.Name

		if (-not $script:dbatoolsAvailable)
		{
			$errMsg = "dbatools-Modul nicht gefunden."
			Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
			throw $errMsg
		}

		# Default-ScheduleDays je BackupType setzen wenn nicht explizit angegeben
		if (-not $PSBoundParameters.ContainsKey('ScheduleDays'))
		{
			switch ($BackupType)
			{
				'FULL' { $ScheduleDays = @('EveryDay') }
				'DIFF' { $ScheduleDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday') }
				'LOG'  { $ScheduleDays = @('EveryDay') }
			}
		}

		# Default-ScheduleTime je BackupType setzen wenn nicht explizit angegeben
		if (-not $PSBoundParameters.ContainsKey('ScheduleTime'))
		{
			switch ($BackupType)
			{
				'FULL' { $ScheduleTime = '20:15' }
				'DIFF' { $ScheduleTime = '20:00' }
				# LOG-Sicherungen sollen den ganzen Tag abdecken, nicht nur ab dem sonst
				# ueblichen Abend-Startpunkt - sonst wuerde "alle 15 Minuten" faktisch nur
				# ein paar Stunden am Abend bedeuten.
				'LOG'  { $ScheduleTime = '00:00' }
			}
		}

		# Default-ScheduleIntervalMinutes je BackupType setzen wenn nicht explizit angegeben
		if (-not $PSBoundParameters.ContainsKey('ScheduleIntervalMinutes'))
		{
			switch ($BackupType)
			{
				'LOG'  { $ScheduleIntervalMinutes = 15 }
				default { $ScheduleIntervalMinutes = 0 }
			}
		}

		# Default-CleanupTime je BackupType setzen wenn nicht explizit angegeben (ausser -NoCleanup)
		if (-not $NoCleanup -and -not $PSBoundParameters.ContainsKey('CleanupTime'))
		{
			switch ($BackupType)
			{
				'FULL' { $CleanupTime = '4w' }
				'DIFF' { $CleanupTime = '2w' }
				'LOG'  { $CleanupTime = '48h' }
			}
		}
		if ($NoCleanup) { $CleanupTime = $null }

		# JobName ohne explizite Angabe aus der Konfiguration lesen, abhaengig von -BackupType -
		# analog zu New-sqmOlaUsrDbBackupJob (OlaJobNameFull/Diff/Log). Vorher war der Default fest
		# auf 'sqm-BackupMaintenance-FULL' verdrahtet, unabhaengig vom gewaehlten BackupType - ein
		# Aufruf mit -BackupType DIFF ohne -JobName legte also einen Job an, der "...FULL" hiess,
		# obwohl er tatsaechlich ein DIFF-Job war.
		if (-not $PSBoundParameters.ContainsKey('JobName') -or [string]::IsNullOrWhiteSpace($JobName))
		{
			$cfg = Get-sqmConfig
			$cfgKey = switch ($BackupType)
			{
				'FULL' { 'BackupMaintenanceJobNameFull' }
				'DIFF' { 'BackupMaintenanceJobNameDiff' }
				'LOG'  { 'BackupMaintenanceJobNameLog' }
			}
			$JobName = if ($cfg[$cfgKey]) { $cfg[$cfgKey] } else { "sqm-BackupMaintenance-$BackupType" }
		}

		$connParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
	}

	process
	{
		$result = [PSCustomObject]@{
			SqlInstance    = $SqlInstance
			JobName        = $JobName
			BackupType     = $BackupType
			StepCommand    = $null
			ProcedureName  = $null
			ScheduleName   = $null
			ScheduleDays   = ($ScheduleDays -join ', ')
			ScheduleTime   = $ScheduleTime
			CleanupTime    = $CleanupTime
			BackupPath     = $BackupPath
			Status         = 'Unknown'
			Message        = $null
		}

		try
		{
			Invoke-sqmLogging -Message "Starte Erstellung des Backup-Maintenance-Jobs '$JobName' auf $SqlInstance" -FunctionName $functionName -Level "INFO"

			# 1. Verbindung herstellen
			$sqlSrv = Connect-DbaInstance @connParams -ErrorAction Stop

			# 1a. Bei -UseExcludeTable: Tabelle synchronisieren und DDL-Trigger sicherstellen
			if ($UseExcludeTable)
			{
				Invoke-sqmLogging -Message "UseExcludeTable: Stelle sicher dass sqm_BackupExclude und DDL-Trigger vorhanden sind." -FunctionName $functionName -Level "INFO"
				$syncParams = @{ SqlInstance = $SqlInstance; SkipAlwaysOnPropagation = $true }
				if ($SqlCredential) { $syncParams['SqlCredential'] = $SqlCredential }
				Sync-sqmBackupExcludeTable @syncParams -ErrorAction SilentlyContinue | Out-Null

				$triggerParams = @{ SqlInstance = $SqlInstance; SkipAlwaysOnPropagation = $true }
				if ($SqlCredential) { $triggerParams['SqlCredential'] = $SqlCredential }
				Register-sqmBackupExcludeTrigger @triggerParams -ErrorAction SilentlyContinue | Out-Null
			}

			# 2. Job-Kategorie sicherstellen
			$existingCat = Get-DbaAgentJobCategory @connParams -Category $JobCategory -ErrorAction SilentlyContinue
			if (-not $existingCat)
			{
				New-DbaAgentJobCategory @connParams -Category $JobCategory -ErrorAction SilentlyContinue | Out-Null
				Invoke-sqmLogging -Message "Job-Kategorie '$JobCategory' wurde erstellt." -FunctionName $functionName -Level "INFO"
			}

			# 3. Bestehenden Job behandeln
			$existingJob = Get-DbaAgentJob @connParams -Job $JobName -ErrorAction SilentlyContinue
			if ($existingJob)
			{
				if (-not $Update)
				{
					$msg = "Job '$JobName' existiert bereits. Verwenden Sie -Update zum Ueberschreiben."
					Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
					$result.Status  = 'AlreadyExists'
					$result.Message = $msg
					return $result
				}
				else
				{
					Remove-DbaAgentJob @connParams -Job $JobName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
					Invoke-sqmLogging -Message "Vorhandener Job '$JobName' wurde entfernt (Update)." -FunctionName $functionName -Level "INFO"
				}
			}

			# 4. EINE generische Prozedur in master statt Skripttext im Job-Step und statt einer
			# Prozedur je Job: alles was sich zwischen FULL/DIFF/LOG und zwischen Instanzen
			# unterscheidet (Verzeichnis, Backup-Typ, Aufbewahrung, Exclude-Tabelle, Mail) ist ein
			# Parameter. Der Job-Step zeigt diese Werte im Klartext und kann direkt dort angepasst
			# werden. Die Prozedur selbst enthaelt keine fest verdrahteten Werte.
			#
			# Hintergrund: frueher waren beide Steps PowerShell-Steps. Der PowerShell-Subsystem-Prozess
			# des SQL Agent blieb reproduzierbar haengen und kehrte nie zurueck - und weil schon Step 1
			# nie fertig wurde, lief das eigentliche Backup ueberhaupt nicht an: Job startet, kein
			# Backup, kommt nie zurueck. Derselbe Befehlstext von Hand in einer PowerShell-Konsole
			# lief dagegen immer sauber durch. Deshalb jetzt reines T-SQL (Subsystem TransactSql).
			$procName = 'sqm_BackupUserDatabases'
			$result.ProcedureName = "master.dbo.$procName"

			# Backup-Verzeichnis zur Anlagezeit aufloesen und im Job-Step sichtbar hinterlegen -
			# der T-SQL-Step kann es nicht selbst aus der Modul-Konfiguration lesen.
			$effBackupDir = $BackupPath
			if (-not $effBackupDir)
			{
				try
				{
					$regQuery = "DECLARE @BackupDirectory NVARCHAR(4000); EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory', @BackupDirectory OUTPUT; SELECT @BackupDirectory AS BackupDirectory;"
					$regResult = Invoke-DbaQuery @connParams -Query $regQuery -ErrorAction Stop
					if ($regResult.BackupDirectory) { $effBackupDir = "$($regResult.BackupDirectory)\Usr-db" }
				}
				catch { }
				if (-not $effBackupDir -and $sqlSrv.BackupDirectory) { $effBackupDir = "$($sqlSrv.BackupDirectory)\Usr-db" }
			}
			if (-not $effBackupDir)
			{
				throw "Backup-Verzeichnis konnte nicht ermittelt werden. Bitte -BackupPath angeben."
			}
			$result.BackupPath = $effBackupDir

			# -CleanupTime ('48h'/'7d'/'4w'/'1m') in Olas @CleanupTime (Stunden, int) umrechnen
			$cleanupHours = $null
			if ($CleanupTime -and $CleanupTime -match '^(\d+)([hdwm])$')
			{
				$cleanupValue = [int]$Matches[1]
				$cleanupHours = switch ($Matches[2])
				{
					'h' { $cleanupValue }
					'd' { $cleanupValue * 24 }
					'w' { $cleanupValue * 24 * 7 }
					'm' { $cleanupValue * 24 * 30 }
				}
			}

			# Ola beachtet die AG-Backup-Preference von sich aus. Ohne -CheckPreferredReplica soll
			# unabhaengig davon gesichert werden, also Preference uebersteuern.
			$overridePreference = if ($CheckPreferredReplica) { 'N' } else { 'Y' }

			# Innerhalb einer Prozedur greift Deferred Name Resolution: master.dbo.sqm_BackupExclude
			# darf direkt referenziert werden, auch wenn die Tabelle beim Anlegen der Prozedur noch
			# nicht existiert (in einem Ad-hoc-Batch waere genau das ein Parse-Fehler).
			$procBody = @'
CREATE PROCEDURE dbo.[sqm_BackupUserDatabases]
    @BackupType               nvarchar(10),           -- 'FULL', 'DIFF' oder 'LOG'
    @Directory                nvarchar(4000),         -- Zielverzeichnis der Sicherungen
    @CleanupTime              int           = NULL,   -- Aufbewahrung in Stunden, NULL = kein Cleanup
    @UseExcludeTable          bit           = 0,      -- master.dbo.sqm_BackupExclude auswerten
    @SyncExcludeTable         bit           = 1,      -- Tabelle vorher mit sys.databases abgleichen
    @IncludeSystemDatabases   bit           = 0,
    @Verify                   nvarchar(1)   = 'Y',
    @Compress                 nvarchar(1)   = 'Y',
    @Checksum                 nvarchar(1)   = 'Y',
    @OverrideBackupPreference nvarchar(1)   = 'Y',    -- 'N' = AG-Backup-Preference beachten
    @LogToTable               nvarchar(1)   = 'Y',
    @MailTo                   nvarchar(500) = NULL,
    @MailProfile              sysname       = N'Default',
    @MailOnSuccess            bit           = 0
AS
BEGIN
    SET NOCOUNT ON;

    /* Sichert jede Datenbank EINZELN ueber Olas master.dbo.DatabaseBackup.
       Jeder Einzelaufruf steckt in TRY/CATCH: eine fehlschlagende Datenbank stoppt den Lauf
       nicht, die Prozedur faellt erst am Ende aus, wenn mindestens eine gescheitert ist. */

    IF OBJECT_ID(N'master.dbo.DatabaseBackup', N'P') IS NULL
    BEGIN
        RAISERROR('Ola Hallengren DatabaseBackup (master.dbo.DatabaseBackup) ist auf dieser Instanz nicht installiert.', 16, 1);
        RETURN;
    END

    IF @BackupType NOT IN (N'FULL', N'DIFF', N'LOG')
    BEGIN
        RAISERROR('@BackupType muss FULL, DIFF oder LOG sein.', 16, 1);
        RETURN;
    END

    DECLARE @dbName     sysname;
    DECLARE @ErrorCount int = 0;
    DECLARE @OkCount    int = 0;
    DECLARE @SkipCount  int = 0;
    DECLARE @IsExcluded bit;
    DECLARE @FailedList nvarchar(max) = N'';
    DECLARE @ErrMsg     nvarchar(2000);

    DECLARE @Current TABLE (DatabaseName sysname PRIMARY KEY);
    INSERT INTO @Current (DatabaseName)
    SELECT name FROM sys.databases
    WHERE  state = 0 AND source_database_id IS NULL
      AND  (database_id > 4 OR (@IncludeSystemDatabases = 1 AND name IN (N'master', N'model', N'msdb')));

    -- Exclude-Tabelle bei Bedarf anlegen und mit dem aktuellen Stand abgleichen
    IF @UseExcludeTable = 1 AND @SyncExcludeTable = 1
    BEGIN
        IF OBJECT_ID(N'master.dbo.sqm_BackupExclude', N'U') IS NULL
        BEGIN
            CREATE TABLE master.dbo.sqm_BackupExclude (
                DatabaseName  sysname       NOT NULL,
                Reason        nvarchar(255) NULL,
                ExcludedBy    sysname       NOT NULL CONSTRAINT DF_sqm_BackupExclude_ExcludedBy DEFAULT SUSER_SNAME(),
                ExcludedAt    datetime2     NOT NULL CONSTRAINT DF_sqm_BackupExclude_ExcludedAt DEFAULT SYSDATETIME(),
                IsActive      bit           NOT NULL CONSTRAINT DF_sqm_BackupExclude_IsActive   DEFAULT 1,
                IsOrphaned    bit           NOT NULL CONSTRAINT DF_sqm_BackupExclude_IsOrphaned DEFAULT 0,
                CONSTRAINT PK_sqm_BackupExclude PRIMARY KEY (DatabaseName)
            );
            PRINT 'Created master.dbo.sqm_BackupExclude.';
        END

        INSERT INTO master.dbo.sqm_BackupExclude (DatabaseName, IsActive, IsOrphaned)
        SELECT c.DatabaseName, 1, 0
        FROM   @Current c
        WHERE  NOT EXISTS (SELECT 1 FROM master.dbo.sqm_BackupExclude e WHERE e.DatabaseName = c.DatabaseName);
        PRINT 'Exclude table: added ' + CAST(@@ROWCOUNT AS varchar(10)) + ' new database(s).';

        UPDATE e SET IsOrphaned = 1
        FROM   master.dbo.sqm_BackupExclude e
        WHERE  e.IsOrphaned = 0
          AND  NOT EXISTS (SELECT 1 FROM @Current c WHERE c.DatabaseName = e.DatabaseName);
        PRINT 'Exclude table: flagged ' + CAST(@@ROWCOUNT AS varchar(10)) + ' orphaned database(s).';

        UPDATE e SET IsOrphaned = 0
        FROM   master.dbo.sqm_BackupExclude e
        WHERE  e.IsOrphaned = 1
          AND  EXISTS (SELECT 1 FROM @Current c WHERE c.DatabaseName = e.DatabaseName);
        PRINT 'Exclude table: un-flagged ' + CAST(@@ROWCOUNT AS varchar(10)) + ' returned database(s).';
    END

    DECLARE @HasExcludeTable bit = CASE WHEN OBJECT_ID(N'master.dbo.sqm_BackupExclude', N'U') IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE dbCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT DatabaseName FROM @Current ORDER BY DatabaseName;

    OPEN dbCursor;
    FETCH NEXT FROM dbCursor INTO @dbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @IsExcluded = 0;
        IF @UseExcludeTable = 1 AND @HasExcludeTable = 1
           AND EXISTS (SELECT 1 FROM master.dbo.sqm_BackupExclude
                       WHERE DatabaseName = @dbName AND IsActive = 0 AND IsOrphaned = 0)
            SET @IsExcluded = 1;

        IF @IsExcluded = 1
        BEGIN
            SET @SkipCount += 1;
            PRINT 'Skipping ' + @dbName + ' (sqm_BackupExclude: IsActive = 0).';
        END
        ELSE
        BEGIN
            BEGIN TRY
                PRINT 'Backing up ' + @dbName + ' (' + @BackupType + ')...';
                EXECUTE master.dbo.DatabaseBackup
                    @Databases                = @dbName,
                    @Directory                = @Directory,
                    @BackupType               = @BackupType,
                    @Verify                   = @Verify,
                    @CleanupTime              = @CleanupTime,
                    @Compress                 = @Compress,
                    @Checksum                 = @Checksum,
                    @OverrideBackupPreference = @OverrideBackupPreference,
                    @LogToTable               = @LogToTable;
                SET @OkCount += 1;
            END TRY
            BEGIN CATCH
                SET @ErrorCount += 1;
                SET @ErrMsg = 'Backup of ' + @dbName + ' failed: ' + ERROR_MESSAGE();
                SET @FailedList += @ErrMsg + CHAR(13) + CHAR(10);
                RAISERROR(@ErrMsg, 10, 1) WITH NOWAIT;
            END CATCH
        END

        FETCH NEXT FROM dbCursor INTO @dbName;
    END

    CLOSE dbCursor;
    DEALLOCATE dbCursor;

    PRINT 'Done. OK: ' + CAST(@OkCount AS varchar(10)) + ', skipped: ' + CAST(@SkipCount AS varchar(10)) + ', failed: ' + CAST(@ErrorCount AS varchar(10)) + '.';

    IF @MailTo IS NOT NULL AND (@ErrorCount > 0 OR @MailOnSuccess = 1)
    BEGIN
        DECLARE @subject nvarchar(255) =
            CASE WHEN @ErrorCount > 0
                 THEN N'[' + @@SERVERNAME + N'] ' + @BackupType + N' Backup FEHLER - ' + CAST(@ErrorCount AS nvarchar(10)) + N' fehlgeschlagen'
                 ELSE N'[' + @@SERVERNAME + N'] ' + @BackupType + N' Backup erfolgreich - ' + CAST(@OkCount AS nvarchar(10)) + N' Datenbanken'
            END;
        DECLARE @body nvarchar(max) =
            N'Instanz: ' + @@SERVERNAME + CHAR(13) + CHAR(10) +
            N'Typ: ' + @BackupType + CHAR(13) + CHAR(10) +
            N'Ziel: ' + @Directory + CHAR(13) + CHAR(10) +
            N'Zeitpunkt: ' + CONVERT(nvarchar(19), SYSDATETIME(), 120) + CHAR(13) + CHAR(10) +
            N'Erfolgreich: ' + CAST(@OkCount AS nvarchar(10)) + CHAR(13) + CHAR(10) +
            N'Uebersprungen: ' + CAST(@SkipCount AS nvarchar(10)) + CHAR(13) + CHAR(10) +
            N'Fehlgeschlagen: ' + CAST(@ErrorCount AS nvarchar(10)) + CHAR(13) + CHAR(10) +
            ISNULL(@FailedList, N'');
        BEGIN TRY
            EXEC msdb.dbo.sp_send_dbmail
                @profile_name = @MailProfile,
                @recipients   = @MailTo,
                @subject      = @subject,
                @body         = @body;
        END TRY
        BEGIN CATCH
            PRINT 'Mail konnte nicht gesendet werden: ' + ERROR_MESSAGE();
        END CATCH
    END

    IF @ErrorCount > 0
        RAISERROR('sqm_BackupUserDatabases: %d Datenbank(en) fehlgeschlagen. Details siehe Step-Ausgabe.', 16, 1, @ErrorCount);
END
'@

			# 5. Job-Step: ruft die Prozedur mit allen Werten im Klartext auf
			$sqlDir     = "N'" + $effBackupDir.Replace("'", "''") + "'"
			$sqlCleanup = if ($null -ne $cleanupHours) { "$cleanupHours" } else { 'NULL' }
			$sqlMailTo  = if ($MailTo) { "N'" + $MailTo.Replace("'", "''") + "'" } else { 'NULL' }
			$sqlProfile = "N'" + $MailProfile.Replace("'", "''") + "'"

			$stepCommand = @"
EXEC master.dbo.[$procName]
     @BackupType               = N'$BackupType',
     @Directory                = $sqlDir,
     @CleanupTime              = $sqlCleanup,
     @UseExcludeTable          = $(if ($UseExcludeTable) { 1 } else { 0 }),
     @SyncExcludeTable         = 1,
     @IncludeSystemDatabases   = $(if ($IncludeSystemDatabases) { 1 } else { 0 }),
     @Verify                   = 'Y',
     @Compress                 = 'Y',
     @Checksum                 = 'Y',
     @OverrideBackupPreference = '$overridePreference',
     @LogToTable               = 'Y',
     @MailTo                   = $sqlMailTo,
     @MailProfile              = $sqlProfile,
     @MailOnSuccess            = $(if ($MailOnSuccess) { 1 } else { 0 });
"@
			$result.StepCommand = $stepCommand

			Invoke-sqmLogging -Message "Job-Step ruft master.dbo.[$procName] mit Parametern auf (Typ $BackupType, Ziel $effBackupDir)." -FunctionName $functionName -Level "INFO"


			# 6. WhatIf-Pruefung
			if (-not $PSCmdlet.ShouldProcess($SqlInstance, "Erstelle Job '$JobName' [$BackupType]"))
			{
				$result.Status  = 'WhatIf'
				$result.Message = "WhatIf: Job '$JobName' wuerde erstellt werden."
				return $result
			}

			# 6b. Prozedur in master anlegen/aktualisieren (CREATE PROCEDURE muss allein im Batch
			# stehen, deshalb zwei getrennte Aufrufe statt DROP und CREATE in einem Query).
			Invoke-DbaQuery @connParams -Database master `
				-Query "IF OBJECT_ID(N'master.dbo.$procName', N'P') IS NOT NULL DROP PROCEDURE dbo.[$procName];" `
				-EnableException -ErrorAction Stop
			Invoke-DbaQuery @connParams -Database master -Query $procBody -EnableException -ErrorAction Stop
			Invoke-sqmLogging -Message "Prozedur master.dbo.[$procName] angelegt/aktualisiert." -FunctionName $functionName -Level "INFO"

			# 7. Job anlegen
			New-DbaAgentJob @connParams `
				-Job $JobName `
				-Category $JobCategory `
				-Description "sqm BackupMaintenance $BackupType (T-SQL) — Ola DatabaseBackup je Datenbank via master.dbo.$procName — $($ScheduleDays -join '/') $ScheduleTime — Ziel: $effBackupDir" `
				-EnableException -ErrorAction Stop | Out-Null

			Invoke-sqmLogging -Message "Job '$JobName' angelegt." -FunctionName $functionName -Level "INFO"

			# 8. Job-Step anlegen: Backup-UserDatabases-<BackupType>
			New-DbaAgentJobStep @connParams `
				-Job $JobName `
				-StepId 1 `
				-StepName "Backup-UserDatabases-$BackupType" `
				-Subsystem TransactSql `
				-Database master `
				-Command $stepCommand `
				-OnSuccessAction QuitWithSuccess `
				-OnFailAction QuitWithFailure `
				-EnableException -ErrorAction Stop | Out-Null

			Invoke-sqmLogging -Message "Step 2 'Backup-UserDatabases-$BackupType' angelegt." -FunctionName $functionName -Level "INFO"

			# 10. Hilfsfunktion: Wochentage aufloesen
			function ConvertTo-WeekdayInterval
			{
				param ([string[]]$Days)
				$expanded = foreach ($d in $Days)
				{
					switch ($d)
					{
						'Weekdays' { 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday' }
						'Weekend'  { 'Saturday', 'Sunday' }
						'EveryDay' { 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday' }
						default    { $d }
					}
				}
				return ($expanded | Select-Object -Unique)
			}

			# 11. Schedule anlegen
			$timeNormal     = $ScheduleTime -replace ':', ''
			$intervalSuffix = if ($ScheduleIntervalMinutes -gt 0) { "_every$($ScheduleIntervalMinutes)min" } else { '' }
			$scheduleName   = "sqm_BackupMaintenance_${BackupType}_${timeNormal}${intervalSuffix}"
			$result.ScheduleName = $scheduleName

			$expandedDays = ConvertTo-WeekdayInterval -Days $ScheduleDays

			$timeParts = $ScheduleTime -split ':'
			$startTime = '{0:D2}{1:D2}00' -f [int]$timeParts[0], [int]$timeParts[1]

			$schedParams = @{
				SqlInstance       = $SqlInstance
				Job               = $JobName
				Schedule          = $scheduleName
				Force             = $true
				FrequencyType     = 'Weekly'
				FrequencyInterval = $expandedDays
				StartTime         = $startTime
			}
			if ($SqlCredential) { $schedParams['SqlCredential'] = $SqlCredential }

			if ($ScheduleIntervalMinutes -gt 0)
			{
				$schedParams['FrequencySubDayType']     = 'Minutes'
				$schedParams['FrequencySubDayInterval'] = $ScheduleIntervalMinutes
				$schedParams['EndTime']                 = '235959'
				Invoke-sqmLogging -Message "Schedule '$scheduleName': woechentlich $($expandedDays -join '/'), Start $ScheduleTime, alle $ScheduleIntervalMinutes Minuten bis 23:59." -FunctionName $functionName -Level "INFO"
			}
			else
			{
				Invoke-sqmLogging -Message "Schedule '$scheduleName': woechentlich $($expandedDays -join '/') um $ScheduleTime." -FunctionName $functionName -Level "INFO"
			}

			New-DbaAgentSchedule @schedParams | Out-Null

			# 12. Operator fuer Fehler-Benachrichtigung
			if ($OperatorName)
			{
				$op = Get-DbaAgentOperator @connParams -Operator $OperatorName -ErrorAction SilentlyContinue
				if ($op)
				{
					Set-DbaAgentJob @connParams -Job $JobName -OperatorToEmail $OperatorName -EmailLevel OnFailure -ErrorAction SilentlyContinue | Out-Null
					Invoke-sqmLogging -Message "Operator '$OperatorName' fuer Fehler-Benachrichtigung gesetzt." -FunctionName $functionName -Level "INFO"
				}
				else
				{
					Invoke-sqmLogging -Message "Operator '$OperatorName' nicht gefunden — Benachrichtigung nicht konfiguriert." -FunctionName $functionName -Level "WARNING"
				}
			}

			$intervalInfo    = if ($ScheduleIntervalMinutes -gt 0) { ", alle $ScheduleIntervalMinutes Min." } else { '' }
			$cleanupInfo     = if ($CleanupTime) { ", Cleanup: $CleanupTime" } else { '' }
			$result.Status   = 'Created'
			$result.Message  = "Job '$JobName' ($BackupType) erstellt. Schedule: $($expandedDays -join '/') $ScheduleTime$intervalInfo$cleanupInfo"
			Invoke-sqmLogging -Message $result.Message -FunctionName $functionName -Level "INFO"
		}
		catch
		{
			$errMsg = $_.Exception.Message
			Invoke-sqmLogging -Message "Fehler bei Erstellung von Job '$JobName': $errMsg" -FunctionName $functionName -Level "ERROR"
			$result.Status  = 'Failed'
			$result.Message = $errMsg
			if ($EnableException) { throw }
		}

		# AlwaysOn-Propagierung: Job auch auf Secondary-Repliken anlegen
		if (-not $SkipAlwaysOnPropagation -and $result.Status -eq 'Created')
		{
			try
			{
				$replicaQuery = "SELECT r.replica_server_name FROM sys.availability_replicas r WHERE r.replica_server_name <> @@SERVERNAME"
				$secondaries = Invoke-DbaQuery @connParams -Database master -Query $replicaQuery -ErrorAction SilentlyContinue

				foreach ($sec in $secondaries)
				{
					$secName = $sec.replica_server_name
					Invoke-sqmLogging -Message "AlwaysOn: Propagiere Job '$JobName' auf Secondary '$secName'." -FunctionName $functionName -Level "INFO"
					try
					{
						$secParams = @{
							SqlInstance             = $secName
							JobName                 = $JobName
							BackupType              = $BackupType
							ScheduleTime            = $ScheduleTime
							ScheduleDays            = $ScheduleDays
							ScheduleIntervalMinutes = $ScheduleIntervalMinutes
							JobCategory             = $JobCategory
							SkipAlwaysOnPropagation = $true
							Update                  = $true
						}
						if ($SqlCredential)          { $secParams['SqlCredential']          = $SqlCredential }
						if ($BackupPath)             { $secParams['BackupPath']             = $BackupPath }
						if ($UseExcludeTable)        { $secParams['UseExcludeTable']        = $true }
						if ($CheckPreferredReplica)  { $secParams['CheckPreferredReplica']  = $true }
						if ($IncludeSystemDatabases) { $secParams['IncludeSystemDatabases'] = $true }
						if ($MailTo)                 { $secParams['MailTo']                 = $MailTo }
						if ($MailOnSuccess)          { $secParams['MailOnSuccess']          = $true }
						if ($OperatorName)           { $secParams['OperatorName']           = $OperatorName }
						if ($CleanupTime)            { $secParams['CleanupTime']            = $CleanupTime }
						else                         { $secParams['NoCleanup']              = $true }
						$secParams['MailProfile'] = $MailProfile

						$secResult = New-sqmBackupMaintenanceJob @secParams
						Invoke-sqmLogging -Message "AlwaysOn '$secName': $($secResult.Status) — $($secResult.Message)" -FunctionName $functionName -Level "INFO"
					}
					catch
					{
						Invoke-sqmLogging -Message "AlwaysOn: Fehler bei Propagierung auf '$secName': $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
					}
				}
			}
			catch
			{
				Invoke-sqmLogging -Message "AlwaysOn-Erkennung nicht verfuegbar oder kein AG konfiguriert." -FunctionName $functionName -Level "VERBOSE"
			}
		}

		return $result
	}
}
