/* ============================================================================
   OlaBackup-UserDatabases.sql

   Plain T-SQL user-database backup script for a SQL Agent "Transact-SQL
   Script (T-SQL)" job step. No PowerShell subsystem involved anywhere, so
   this does not depend on the SQL Agent PowerShell host and cannot hang
   after a successful run the way a PowerShell-subsystem step can.

   What it does:
     1. Builds the candidate database list from @Databases below
        (ALL_DATABASES / USER_DATABASES / an explicit comma-separated list).
     2. Opens a cursor over that list, one database at a time.
     3. For each database, if master.dbo.sqm_BackupExclude exists and marks
        that database IsActive = 0 AND IsOrphaned = 0, it is skipped.
        Otherwise it calls Ola Hallengren's master.dbo.DatabaseBackup for
        that ONE database (@Databases = @dbName), so one bad/oversized
        database can fail without ever touching the others.
     4. Wraps each per-database call in TRY/CATCH: a failure is logged with
        RAISERROR (visible in the job's Agent history / output file) and the
        loop continues with the next database instead of aborting the job.

   Prerequisites:
     - Ola Hallengren's Maintenance Solution must already be installed on
       this instance (master.dbo.DatabaseBackup must exist). If it doesn't,
       either run Install-sqmOlaMaintenanceSolution from sqmSQLTool, or get
       DatabaseBackup.sql from https://ola.hallengren.com and run it once
       against master.
     - master.dbo.sqm_BackupExclude is optional. If it doesn't exist, every
       database in the candidate list is backed up (no exclusions).

   Usage:
     Edit the CONFIGURATION block below, then paste the whole script as the
     command of a SQL Agent job step with Type = "Transact-SQL Script
     (T-SQL)", database = master. Create one job (and one copy of this
     script with @BackupType changed) per backup type - FULL, DIFF, LOG -
     each with its own schedule, exactly like New-sqmOlaUsrDbBackupJob does.
   ============================================================================ */

SET NOCOUNT ON;

/* ============================== CONFIGURATION ==============================
   Edit these values for this job, then save/paste the whole script as-is. */

DECLARE @BackupType   nvarchar(20)  = N'FULL';               -- 'FULL', 'DIFF', or 'LOG'
DECLARE @Databases     nvarchar(max) = N'USER_DATABASES';     -- 'ALL_DATABASES', 'USER_DATABASES', or 'DB1,DB2,DB3'
DECLARE @Directory     nvarchar(max) = N'D:\Backup\Usr-db';   -- backup target directory
DECLARE @CleanupTime   int           = 48;                    -- hours; NULL = no cleanup
DECLARE @Compress      nvarchar(max) = N'Y';                  -- 'Y' / 'N'
DECLARE @Verify        nvarchar(max) = N'Y';                  -- 'Y' / 'N'
DECLARE @Checksum      nvarchar(max) = N'Y';                  -- 'Y' / 'N'
DECLARE @LogToTable    nvarchar(max) = N'Y';                  -- 'Y' / 'N' - logs into master.dbo.CommandLog

/* ============================================================================
   From here on nothing needs editing per job. */

DECLARE @dbName           sysname;
DECLARE @HasExcludeTable  bit = CASE WHEN OBJECT_ID(N'master.dbo.sqm_BackupExclude', N'U') IS NOT NULL THEN 1 ELSE 0 END;
DECLARE @ErrorCount       int = 0;
DECLARE @ErrMsg           nvarchar(4000);
DECLARE @IsExcluded       bit;
-- Built and run via sp_executesql, not referenced directly: an ad-hoc batch (unlike a stored
-- procedure) binds every table name at parse time, even in a branch that never runs, so a plain
-- "IF @HasExcludeTable = 1 AND EXISTS (SELECT ... FROM sqm_BackupExclude)" fails to even PARSE
-- with "Invalid object name" when the table doesn't exist, regardless of @HasExcludeTable's value.
DECLARE @ExcludeCheckSql  nvarchar(max) = N'SELECT @IsExcludedOut = 1 FROM master.dbo.sqm_BackupExclude WHERE DatabaseName = @db AND IsActive = 0 AND IsOrphaned = 0';

DECLARE @DbList TABLE (DatabaseName sysname PRIMARY KEY);

IF @Databases = N'ALL_DATABASES'
    INSERT INTO @DbList (DatabaseName)
    SELECT name FROM sys.databases WHERE state = 0;
ELSE IF @Databases = N'USER_DATABASES'
    INSERT INTO @DbList (DatabaseName)
    SELECT name FROM sys.databases WHERE state = 0 AND database_id > 4 AND source_database_id IS NULL;
ELSE
    INSERT INTO @DbList (DatabaseName)
    SELECT d.name
    FROM   STRING_SPLIT(@Databases, ',') s
    JOIN   sys.databases d ON d.name = LTRIM(RTRIM(s.value)) AND d.state = 0;

IF NOT EXISTS (SELECT 1 FROM @DbList)
BEGIN
    RAISERROR('OlaBackup-UserDatabases: no candidate databases matched @Databases = ''%s''.', 16, 1, @Databases);
    RETURN;
END

DECLARE dbCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM @DbList ORDER BY DatabaseName;

OPEN dbCursor;
FETCH NEXT FROM dbCursor INTO @dbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @IsExcluded = 0;
    IF @HasExcludeTable = 1
    BEGIN
        EXEC sp_executesql @ExcludeCheckSql,
            N'@db sysname, @IsExcludedOut bit OUTPUT',
            @db = @dbName, @IsExcludedOut = @IsExcluded OUTPUT;
    END

    IF @IsExcluded = 1
    BEGIN
        PRINT 'Skipping ' + @dbName + ' (sqm_BackupExclude: IsActive = 0).';
    END
    ELSE
    BEGIN
        BEGIN TRY
            PRINT 'Backing up ' + @dbName + ' (' + @BackupType + ')...';

            EXECUTE master.dbo.DatabaseBackup
                @Databases   = @dbName,
                @Directory   = @Directory,
                @BackupType  = @BackupType,
                @Verify      = @Verify,
                @CleanupTime = @CleanupTime,
                @Compress    = @Compress,
                @Checksum    = @Checksum,
                @LogToTable  = @LogToTable;
        END TRY
        BEGIN CATCH
            SET @ErrorCount += 1;
            SET @ErrMsg = 'Backup of ' + @dbName + ' failed: ' + ERROR_MESSAGE();
            RAISERROR(@ErrMsg, 10, 1) WITH NOWAIT;
            -- Deliberately not re-thrown: one bad database must not stop the rest of the run.
        END CATCH
    END

    FETCH NEXT FROM dbCursor INTO @dbName;
END

CLOSE dbCursor;
DEALLOCATE dbCursor;

IF @ErrorCount > 0
BEGIN
    -- Fails the job step (and so the job) only after every database was attempted,
    -- so the SQL Agent job history correctly reflects "N database(s) failed" while
    -- every other database still got backed up.
    RAISERROR('OlaBackup-UserDatabases: %d database(s) failed. See preceding messages / job output file.', 16, 1, @ErrorCount);
END
