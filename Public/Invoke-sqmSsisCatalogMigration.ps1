<#
.SYNOPSIS
    Migrates an SSIS catalog (SSISDB) to a new server and upgrades its schema to the version of
    the destination instance.

.DESCRIPTION
    Moving an SSIS catalog is not a database move. SSISDB carries a database master key, and every
    sensitive value in it - connection manager passwords, environment variables marked sensitive,
    project parameters - is encrypted with that key. A plain backup/restore lands a database on the
    new server whose master key the new server cannot open, and SSIS then fails at execution time,
    not at restore time. On top of that, the restore turns TRUSTWORTHY off, sets the owner to
    whoever ran the restore, and leaves the catalog at the schema version of the OLD server.

    This function performs the whole documented sequence in one run and reports every step:

      1. Assessment of source and destination: catalog inventory (folders, projects, packages,
         environments), schema version, master key state, TRUSTWORTHY, owner, CLR, SQL Server
         version, the SSIS Server Maintenance Job and the sp_ssis_startup procedure.
      2. Validation of -CatalogPassword against the SOURCE master key before anything is changed,
         by opening and closing the key. A wrong password is the single most common way this
         migration fails halfway through, and it is free to rule out up front.
      3. Backup of the database master key to a file, and a full backup of SSISDB.
      4. Destination preparation: CLR enabled, and the catalog created if it does not exist yet.
         The catalog must be created on the destination BEFORE the restore: creating it installs
         the CLR assemblies and the server-level SSIS objects that live outside SSISDB, which a
         database restore does not bring along.
      5. Restore of SSISDB over the freshly created catalog, delegated to Invoke-sqmRestoreDatabase
         so the exclusive-access handling (single user, killing foreign sessions, retry) is the
         same proven path used for every other restore in this module.
      6. Post-restore fix-up: TRUSTWORTHY back on, owner set to sa, the master key re-encrypted by
         the destination's service master key, catalog.startup to clean up operation states that
         were left running on the old server, and orphaned SSISDB users re-mapped.
      7. Schema upgrade check. The reference is NOT a hard-coded version table: the catalog created
         on the destination in step 4 reports the schema version that this destination server
         produces, and that value is recorded before the restore overwrites it. Comparing it with
         the restored schema version afterwards says exactly whether an upgrade is needed.
      8. Optionally the upgrade itself via ISDBUpgradeWizard.exe (-UpgradeCatalog), verified by
         re-reading the schema version afterwards rather than by trusting the exit code.

    Nothing on the source is changed at any point. The source catalog stays online and usable; the
    only source-side operations are reads plus two backups.

    -AssessOnly stops after step 2 and returns the full picture with the blockers found. That is
    the intended way to plan the migration; the migration itself is a separate, deliberate run.

.PARAMETER SourceSqlInstance
    Instance holding the SSIS catalog to migrate.

.PARAMETER SourceSqlCredential
    PSCredential for the source connection.

.PARAMETER DestinationSqlInstance
    Instance that receives the catalog. Must be the same or a higher SQL Server major version - a
    backup cannot be restored to a lower version, and the function refuses such a run.

.PARAMETER DestinationSqlCredential
    PSCredential for the destination connection.

.PARAMETER CatalogPassword
    The SSISDB master key password (SecureString). Required for everything except -AssessOnly. This
    is the password that was set when the catalog was created; without it the encrypted content of
    the catalog cannot be carried over.

.PARAMETER KeyFilePassword
    Password protecting the exported master key FILE (SecureString). Defaults to -CatalogPassword.
    Set it when the key backup is handed over separately from the catalog password.

.PARAMETER SharedPath
    Directory for the SSISDB backup and the master key file, reachable by both instances (a UNC
    share in the normal case). Both files are written by the respective SQL Server service account,
    so that account needs write access. Without it, the source instance's default backup directory
    is used - only useful when both instances see the same path.

.PARAMETER DestinationDataPath
    Target directory for the SSISDB data file on the destination. Default: the destination's own
    default data directory.

.PARAMETER DestinationLogPath
    Target directory for the SSISDB log file on the destination. Default: the destination's own
    default log directory.

.PARAMETER AssessOnly
    Only assess source and destination and report what would happen, including blockers. Changes
    nothing anywhere.

.PARAMETER UseKeyBackupRestore
    Re-key the destination with RESTORE MASTER KEY FROM FILE instead of the default
    OPEN MASTER KEY + ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY. Only needed when the
    restored key cannot be opened with -CatalogPassword. Restoring over an existing master key
    requires FORCE, which discards anything the old key still protects, so this path additionally
    requires -Force and says so instead of quietly forcing.

.PARAMETER UpgradeCatalog
    Run the catalog schema upgrade on the destination when the restored catalog is older than the
    destination server. Without this switch the need for an upgrade is reported but nothing is run.

.PARAMETER UpgradeWizardPath
    Full path to ISDBUpgradeWizard.exe. Without it the function looks for the highest-numbered
    "<ProgramFiles>\Microsoft SQL Server\<nnn>\DTS\Binn\ISDBUpgradeWizard.exe" on the machine this
    function runs on. The wizard is a Windows tool, not T-SQL: it has to be run on a machine that
    can reach the destination instance.

.PARAMETER UpgradeWizardArgument
    Argument list for the upgrade wizard. Default: -S <destination> -q (silent). Override it when
    your SQL Server build expects a different syntax - the result is verified by re-reading the
    catalog schema version afterwards, so a wrong argument list shows up as "upgrade did not take
    effect" rather than as a false success.

.PARAMETER SkipAgentJobScan
    Skip the scan for SQL Agent jobs that start packages from the catalog. That scan does not touch
    the migration itself; it lists the jobs on the SOURCE that still point at the old server and
    will have to be repointed once the catalog has moved.

.PARAMETER Force
    Allow the destination SSISDB to be overwritten if it already exists, and allow the FORCE
    variant of RESTORE MASTER KEY together with -UseKeyBackupRestore.

.PARAMETER OutputPath
    Directory for the HTML report. Default: <OutputPath config>\SsisCatalogMigration.

.PARAMETER NoOpen
    Do not open the report after the run.

.PARAMETER NoReport
    Do not write a report at all.

.PARAMETER EnableException
    Throw exceptions immediately instead of returning a result object with Status 'Failed'.

.EXAMPLE
    Invoke-sqmSsisCatalogMigration -SourceSqlInstance "SQLOLD" -DestinationSqlInstance "SQLNEW" -AssessOnly

    The planning run: what is in the catalog, what is missing on the destination, what would block
    the migration. Changes nothing.

.EXAMPLE
    $pw = Read-Host "SSISDB master key password" -AsSecureString
    Invoke-sqmSsisCatalogMigration -SourceSqlInstance "SQLOLD" -DestinationSqlInstance "SQLNEW" `
        -CatalogPassword $pw -SharedPath "\\fileserver\sqlmove" -UpgradeCatalog

    The migration itself, including the schema upgrade on the newer destination server.

.EXAMPLE
    Invoke-sqmSsisCatalogMigration -SourceSqlInstance "SQLOLD" -DestinationSqlInstance "SQLNEW" `
        -CatalogPassword $pw -SharedPath "\\fileserver\sqlmove" -WhatIf

    Shows every change that would be made, in order, without making any of them.

.NOTES
    Requires dbatools, sysadmin on both instances, and Integration Services installed on the
    destination (the catalog cannot be created without it).

    What this function does NOT do: it does not touch the source catalog, it does not repoint SQL
    Agent jobs (it lists them), and it does not move the SSIS service configuration or file system
    packages - only the catalog. Packages stored in the file system or in MSDB are a different
    migration.

.LINK
    Invoke-sqmSsisConfiguration
    Invoke-sqmRestoreDatabase
    Find-sqmAgentJobReference
    Test-sqmSSISPackageCompatibility
#>
function Invoke-sqmSsisCatalogMigration
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$SourceSqlInstance,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SourceSqlCredential,

        [Parameter(Mandatory = $true)]
        [string]$DestinationSqlInstance,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$DestinationSqlCredential,

        [Parameter(Mandatory = $false)]
        [System.Security.SecureString]$CatalogPassword,

        [Parameter(Mandatory = $false)]
        [System.Security.SecureString]$KeyFilePassword,

        [Parameter(Mandatory = $false)]
        [string]$SharedPath,

        [Parameter(Mandatory = $false)]
        [string]$DestinationDataPath,

        [Parameter(Mandatory = $false)]
        [string]$DestinationLogPath,

        [Parameter(Mandatory = $false)]
        [switch]$AssessOnly,

        [Parameter(Mandatory = $false)]
        [switch]$UseKeyBackupRestore,

        [Parameter(Mandatory = $false)]
        [switch]$UpgradeCatalog,

        [Parameter(Mandatory = $false)]
        [string]$UpgradeWizardPath,

        [Parameter(Mandatory = $false)]
        [string[]]$UpgradeWizardArgument,

        [Parameter(Mandatory = $false)]
        [switch]$SkipAgentJobScan,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath = (Join-Path (Get-sqmDefaultOutputPath) 'SsisCatalogMigration'),

        [Parameter(Mandatory = $false)]
        [switch]$NoOpen,

        [Parameter(Mandatory = $false)]
        [switch]$NoReport,

        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name

        if (-not $script:dbatoolsAvailable)
        {
            $errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
            throw $errMsg
        }

        if (-not $AssessOnly -and -not $CatalogPassword)
        {
            $errMsg = "-CatalogPassword ist fuer die Migration erforderlich (nur -AssessOnly kommt ohne aus). Ohne das Master-Key-Kennwort laesst sich der verschluesselte Inhalt des Katalogs nicht mitnehmen."
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
            throw $errMsg
        }

        # SecureString -> Klartext. Der BSTR wird explizit wieder genullt und freigegeben; ein
        # einfaches PtrToStringAuto ohne finally laesst das Kennwort im Prozessspeicher stehen.
        $toPlain = {
            param ([System.Security.SecureString]$Secure)
            if (-not $Secure) { return '' }
            $ptr = [System.IntPtr]::Zero
            try
            {
                $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
                return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)
            }
            finally
            {
                if ($ptr -ne [System.IntPtr]::Zero)
                {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
                }
            }
        }

        $steps = [System.Collections.Generic.List[PSCustomObject]]::new()
        $addStep = {
            param ([string]$Step, [string]$Status, [string]$Detail)
            $steps.Add([PSCustomObject]@{
                    Step      = $Step
                    Status    = $Status
                    Detail    = $Detail
                    Timestamp = Get-Date
                })
            $level = 'INFO'
            if ($Status -eq 'Failed') { $level = 'ERROR' }
            elseif ($Status -eq 'Blocked' -or $Status -eq 'Warning') { $level = 'WARNING' }
            Invoke-sqmLogging -Message "[$Status] $Step - $Detail" -FunctionName $functionName -Level $level
        }

        # Berichtskoerper. Das Rahmen-HTML (Theme, Kopf, Fuss) kommt aus ConvertTo-sqmHtmlReport,
        # hier entstehen nur die Tabellen.
        $htmlEncode = {
            param ($Value)
            if ($null -eq $Value) { return '' }
            return ([string]$Value -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
        }

        $buildReportBody = {
            param ($Result, $StepList)

            $sb = [System.Text.StringBuilder]::new()

            $null = $sb.AppendLine("<h2>Ergebnis</h2><table>")
            $null = $sb.AppendLine("<tr><th>Feld</th><th>Wert</th></tr>")
            foreach ($pair in @(
                    @('Quelle', $Result.SourceSqlInstance),
                    @('Ziel', $Result.DestinationSqlInstance),
                    @('Aktion', $Result.Action),
                    @('Status', $Result.Status),
                    @('Begruendung', $Result.Reason),
                    @('Schemaversion Quelle', $Result.SchemaVersionSource),
                    @('Schemaversion Ziel', $Result.SchemaVersionDestination),
                    @('Upgrade erforderlich', $Result.UpgradeRequired),
                    @('Upgrade-Ergebnis', $Result.UpgradeResult),
                    @('Backupdatei', $Result.BackupFile),
                    @('Master-Key-Datei', $Result.MasterKeyFile)))
            {
                $null = $sb.AppendLine("<tr><td>$(& $htmlEncode $pair[0])</td><td>$(& $htmlEncode $pair[1])</td></tr>")
            }
            $null = $sb.AppendLine("</table>")

            foreach ($side in @(@('Quelle', $Result.Source), @('Ziel', $Result.Destination)))
            {
                if (-not $side[1]) { continue }
                $null = $sb.AppendLine("<h2>$($side[0])</h2><table><tr><th>Eigenschaft</th><th>Wert</th></tr>")
                foreach ($prop in $side[1].PSObject.Properties)
                {
                    if ($null -eq $prop.Value -or "$($prop.Value)" -eq '') { continue }
                    $null = $sb.AppendLine("<tr><td>$(& $htmlEncode $prop.Name)</td><td>$(& $htmlEncode $prop.Value)</td></tr>")
                }
                $null = $sb.AppendLine("</table>")
            }

            $null = $sb.AppendLine("<h2>Schritte</h2><table><tr><th>Zeit</th><th>Schritt</th><th>Status</th><th>Detail</th></tr>")
            foreach ($s in $StepList)
            {
                $cls = 'ok'
                if ($s.Status -eq 'Failed') { $cls = 'crit' }
                elseif ($s.Status -eq 'Blocked' -or $s.Status -eq 'Warning' -or $s.Status -eq 'WhatIf') { $cls = 'warn' }
                $null = $sb.AppendLine("<tr><td>$($s.Timestamp.ToString('HH:mm:ss'))</td><td>$(& $htmlEncode $s.Step)</td><td class='$cls'>$(& $htmlEncode $s.Status)</td><td>$(& $htmlEncode $s.Detail)</td></tr>")
            }
            $null = $sb.AppendLine("</table>")

            $jobs = @($Result.AgentJobsToRepoint)
            if ($jobs.Count -gt 0)
            {
                $null = $sb.AppendLine("<h2>Agent-Jobs, die nach dem Umzug umgehaengt werden muessen</h2>")
                $null = $sb.AppendLine("<table><tr><th>Job</th><th>Step</th><th>Subsystem</th><th>Fundzeile</th></tr>")
                foreach ($j in $jobs)
                {
                    $null = $sb.AppendLine("<tr><td>$(& $htmlEncode $j.JobName)</td><td>$(& $htmlEncode $j.StepName)</td><td>$(& $htmlEncode $j.Subsystem)</td><td>$(& $htmlEncode $j.LineText)</td></tr>")
                }
                $null = $sb.AppendLine("</table>")
            }

            return $sb.ToString()
        }

        $srcConn = @{ SqlInstance = $SourceSqlInstance }
        if ($SourceSqlCredential) { $srcConn['SqlCredential'] = $SourceSqlCredential }
        $dstConn = @{ SqlInstance = $DestinationSqlInstance }
        if ($DestinationSqlCredential) { $dstConn['SqlCredential'] = $DestinationSqlCredential }

        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    }

    process
    {
        $blockers = [System.Collections.Generic.List[string]]::new()

        $result = [PSCustomObject]@{
            SourceSqlInstance      = $SourceSqlInstance
            DestinationSqlInstance = $DestinationSqlInstance
            Action                 = 'Migrate'
            Status                 = 'Unknown'
            Reason                 = ''
            Source                 = $null
            Destination            = $null
            SchemaVersionSource    = $null
            SchemaVersionDestination = $null
            UpgradeRequired        = $null
            UpgradeResult          = 'NotAttempted'
            BackupFile             = $null
            MasterKeyFile          = $null
            AgentJobsToRepoint     = @()
            Steps                  = $steps
            ReportFile             = $null
            Timestamp              = Get-Date
        }
        if ($AssessOnly) { $result.Action = 'Assess' }

        try
        {
            # ==============================================================
            # 1. Quelle bewerten
            # ==============================================================
            $srcServerSql = @'
SELECT
    CASE WHEN DB_ID('SSISDB') IS NULL THEN 0 ELSE 1 END AS SsisDbExists,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50))  AS ProductVersion,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128))        AS Edition,
    CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(4000)) AS DefaultBackupPath,
    ISNULL((SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'clr enabled'), 0) AS ClrEnabled,
    (SELECT COUNT(*) FROM master.sys.procedures WHERE name = 'sp_ssis_startup')          AS StartupProcCount,
    (SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name = 'SSIS Server Maintenance Job')   AS MaintenanceJobCount
'@
            $srcServer = @(Invoke-DbaQuery @srcConn -Database master -Query $srcServerSql -EnableException -As PSObject)[0]

            $source = [PSCustomObject]@{
                SqlInstance         = $SourceSqlInstance
                ProductVersion      = [string]$srcServer.ProductVersion
                Edition             = [string]$srcServer.Edition
                SsisDbExists        = ([int]$srcServer.SsisDbExists -eq 1)
                ClrEnabled          = ([int]$srcServer.ClrEnabled -eq 1)
                HasStartupProc      = ([int]$srcServer.StartupProcCount -gt 0)
                HasMaintenanceJob   = ([int]$srcServer.MaintenanceJobCount -gt 0)
                DatabaseState       = $null
                IsTrustworthy       = $null
                MasterKeyPresent    = $null
                MasterKeyByService  = $null
                DbOwner             = $null
                SizeMB              = $null
                SchemaVersion       = $null
                SchemaBuild         = $null
                EncryptionAlgorithm = $null
                RetentionWindow     = $null
                FolderCount         = $null
                ProjectCount        = $null
                PackageCount        = $null
                EnvironmentCount    = $null
                CatalogReadError    = $null
            }

            if (-not $source.SsisDbExists)
            {
                $blockers.Add("Auf der Quelle '$SourceSqlInstance' existiert keine SSISDB - es gibt keinen Katalog zu migrieren.")
                & $addStep 'Quelle bewerten' 'Blocked' "Keine SSISDB auf '$SourceSqlInstance'."
            }
            else
            {
                $srcDbSql = @'
SELECT
    d.state_desc                        AS DatabaseState,
    d.is_trustworthy_on                 AS IsTrustworthy,
    d.is_master_key_encrypted_by_server AS MasterKeyByService,
    SUSER_SNAME(d.owner_sid)            AS DbOwner,
    (SELECT CAST(SUM(size) * 8.0 / 1024 AS decimal(18,2))
       FROM sys.master_files WHERE database_id = d.database_id) AS SizeMB
FROM sys.databases d
WHERE d.name = 'SSISDB'
'@
                $srcDb = @(Invoke-DbaQuery @srcConn -Database master -Query $srcDbSql -EnableException -As PSObject)[0]
                $source.DatabaseState = [string]$srcDb.DatabaseState
                $source.IsTrustworthy = [bool]$srcDb.IsTrustworthy
                $source.MasterKeyByService = [bool]$srcDb.MasterKeyByService
                $source.DbOwner = [string]$srcDb.DbOwner
                $source.SizeMB = $srcDb.SizeMB

                # Der Hauptschluessel wird BEWUSST getrennt von den Katalogsichten abgefragt.
                # Beides in einer Abfrage hatte einen Fehler: faellt catalog.catalog_properties aus
                # (halb gelaufener Umzug, beschaedigter Katalog), ist auch das Ergebnis der
                # Schluesselpruefung unbekannt - und damit wurde anschliessend die Kennwortpruefung
                # stillschweigend uebersprungen, also genau die Pruefung, die in diesem Zustand am
                # wichtigsten ist. Gegen einen echten Server nachgestellt und danach getrennt.
                try
                {
                    $dmkRow = @(Invoke-DbaQuery @srcConn -Database SSISDB -EnableException -As PSObject `
                            -Query "SELECT COUNT(*) AS DmkCount FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##'")
                    $source.MasterKeyPresent = ($dmkRow.Count -gt 0 -and [int]$dmkRow[0].DmkCount -gt 0)
                }
                catch
                {
                    & $addStep 'Quelle bewerten' 'Warning' "Hauptschluessel der Quell-SSISDB nicht pruefbar: $($_.Exception.Message)"
                }

                # Katalogsichten getrennt lesen: eine SSISDB, die nach einem halb gelaufenen Umzug
                # beschaedigt ist, soll die Bewertung nicht abbrechen, sondern als Befund erscheinen.
                try
                {
                    $srcCatSql = @'
SELECT
    (SELECT CAST(property_value AS nvarchar(128)) FROM catalog.catalog_properties WHERE property_name = 'SCHEMA_VERSION')        AS SchemaVersion,
    (SELECT CAST(property_value AS nvarchar(128)) FROM catalog.catalog_properties WHERE property_name = 'SCHEMA_BUILD')          AS SchemaBuild,
    (SELECT CAST(property_value AS nvarchar(128)) FROM catalog.catalog_properties WHERE property_name = 'ENCRYPTION_ALGORITHM')  AS EncryptionAlgorithm,
    (SELECT CAST(property_value AS nvarchar(128)) FROM catalog.catalog_properties WHERE property_name = 'RETENTION_WINDOW')      AS RetentionWindow,
    (SELECT COUNT(*) FROM catalog.folders)      AS FolderCount,
    (SELECT COUNT(*) FROM catalog.projects)     AS ProjectCount,
    (SELECT COUNT(*) FROM catalog.packages)     AS PackageCount,
    (SELECT COUNT(*) FROM catalog.environments) AS EnvironmentCount
'@
                    $srcCat = @(Invoke-DbaQuery @srcConn -Database SSISDB -Query $srcCatSql -EnableException -As PSObject)[0]
                    $source.SchemaVersion = [string]$srcCat.SchemaVersion
                    $source.SchemaBuild = [string]$srcCat.SchemaBuild
                    $source.EncryptionAlgorithm = [string]$srcCat.EncryptionAlgorithm
                    $source.RetentionWindow = [string]$srcCat.RetentionWindow
                    $source.FolderCount = [int]$srcCat.FolderCount
                    $source.ProjectCount = [int]$srcCat.ProjectCount
                    $source.PackageCount = [int]$srcCat.PackageCount
                    $source.EnvironmentCount = [int]$srcCat.EnvironmentCount

                    & $addStep 'Quelle bewerten' 'Success' ("SSISDB $($source.SizeMB) MB, Schema $($source.SchemaVersion), $($source.FolderCount) Ordner / $($source.ProjectCount) Projekte / $($source.PackageCount) Pakete / $($source.EnvironmentCount) Umgebungen.")
                }
                catch
                {
                    $source.CatalogReadError = $_.Exception.Message
                    $blockers.Add("Die Katalogsichten in der Quell-SSISDB sind nicht lesbar: $($_.Exception.Message)")
                    & $addStep 'Quelle bewerten' 'Blocked' "Katalogsichten nicht lesbar: $($_.Exception.Message)"
                }

                if ($source.MasterKeyPresent -eq $false)
                {
                    $blockers.Add("Die Quell-SSISDB hat keinen Datenbank-Hauptschluessel (##MS_DatabaseMasterKey##) - das ist keine funktionsfaehige Katalogdatenbank.")
                }
            }
            $result.Source = $source
            $result.SchemaVersionSource = $source.SchemaVersion

            # ==============================================================
            # 2. Ziel bewerten
            # ==============================================================
            $dstServerSql = @'
SELECT
    CASE WHEN DB_ID('SSISDB') IS NULL THEN 0 ELSE 1 END AS SsisDbExists,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50))  AS ProductVersion,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128))        AS Edition,
    CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(4000)) AS DefaultBackupPath,
    ISNULL((SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'clr enabled'), 0) AS ClrEnabled,
    (SELECT COUNT(*) FROM master.sys.procedures WHERE name = 'sp_ssis_startup')        AS StartupProcCount,
    (SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name = 'SSIS Server Maintenance Job') AS MaintenanceJobCount
'@
            $dstServer = @(Invoke-DbaQuery @dstConn -Database master -Query $dstServerSql -EnableException -As PSObject)[0]

            $destination = [PSCustomObject]@{
                SqlInstance       = $DestinationSqlInstance
                ProductVersion    = [string]$dstServer.ProductVersion
                Edition           = [string]$dstServer.Edition
                SsisDbExists      = ([int]$dstServer.SsisDbExists -eq 1)
                ClrEnabled        = ([int]$dstServer.ClrEnabled -eq 1)
                HasStartupProc    = ([int]$dstServer.StartupProcCount -gt 0)
                HasMaintenanceJob = ([int]$dstServer.MaintenanceJobCount -gt 0)
                CatalogCreated    = $false
                SchemaVersion     = $null
                SchemaBuild       = $null
            }

            # Ein Backup laesst sich nicht auf eine aeltere Hauptversion zurueckspielen. Das faellt
            # sonst erst beim RESTORE auf - nach dem Backup, nach dem Anlegen des Katalogs.
            $srcMajor = 0
            $dstMajor = 0
            try { $srcMajor = ([version]$source.ProductVersion).Major } catch { }
            try { $dstMajor = ([version]$destination.ProductVersion).Major } catch { }
            if ($srcMajor -gt 0 -and $dstMajor -gt 0 -and $dstMajor -lt $srcMajor)
            {
                $blockers.Add("Das Ziel '$DestinationSqlInstance' ($($destination.ProductVersion)) ist aelter als die Quelle ($($source.ProductVersion)). Ein Backup laesst sich nicht auf eine aeltere Hauptversion zurueckspielen.")
            }

            if ($destination.SsisDbExists -and -not $Force)
            {
                $blockers.Add("Auf dem Ziel '$DestinationSqlInstance' existiert bereits eine SSISDB. Mit -Force wird sie ueberschrieben - ohne -Force passiert nichts.")
            }

            if ($destination.SsisDbExists)
            {
                try
                {
                    $dstCatSql = @'
SELECT
    (SELECT CAST(property_value AS nvarchar(128)) FROM catalog.catalog_properties WHERE property_name = 'SCHEMA_VERSION') AS SchemaVersion,
    (SELECT CAST(property_value AS nvarchar(128)) FROM catalog.catalog_properties WHERE property_name = 'SCHEMA_BUILD')   AS SchemaBuild
'@
                    $dstCat = @(Invoke-DbaQuery @dstConn -Database SSISDB -Query $dstCatSql -EnableException -As PSObject)[0]
                    $destination.SchemaVersion = [string]$dstCat.SchemaVersion
                    $destination.SchemaBuild = [string]$dstCat.SchemaBuild
                }
                catch
                {
                    & $addStep 'Ziel-Katalog lesen' 'Warning' "Vorhandene SSISDB auf dem Ziel, aber die Katalogsichten sind nicht lesbar: $($_.Exception.Message)"
                }
            }

            $result.Destination = $destination
            $result.SchemaVersionDestination = $destination.SchemaVersion
            & $addStep 'Ziel bewerten' 'Success' ("$($destination.ProductVersion), CLR " + $(if ($destination.ClrEnabled) { 'aktiv' } else { 'inaktiv' }) + ", SSISDB " + $(if ($destination.SsisDbExists) { 'vorhanden' } else { 'nicht vorhanden' }) + ".")

            # ==============================================================
            # 3. Kennwort gegen den Quell-Hauptschluessel pruefen
            # ==============================================================
            # Das kostet eine Abfrage und verhindert den haeufigsten Abbruch: die Migration laeuft
            # bis zum Zielserver durch und scheitert erst beim Umschluesseln, wenn das Kennwort
            # falsch war. Geprueft wird durch OEFFNEN des Schluessels, nicht ueber den Fehlertext -
            # der ist je nach Sprachversion des Servers unterschiedlich.
            $passwordVerified = $null
            if ($CatalogPassword -and $source.SsisDbExists -and $source.MasterKeyPresent)
            {
                $pwPlain = & $toPlain $CatalogPassword
                $openSql = "OPEN MASTER KEY DECRYPTION BY PASSWORD = N'$($pwPlain -replace "'", "''")'; CLOSE MASTER KEY;"
                try
                {
                    Invoke-DbaQuery @srcConn -Database SSISDB -Query $openSql -EnableException | Out-Null
                    $passwordVerified = $true
                    & $addStep 'Master-Key-Kennwort pruefen' 'Success' 'Der Hauptschluessel der Quell-SSISDB laesst sich mit -CatalogPassword oeffnen.'
                }
                catch
                {
                    $passwordVerified = $false
                    $blockers.Add("Der Hauptschluessel der Quell-SSISDB laesst sich mit -CatalogPassword nicht oeffnen: $($_.Exception.Message)")
                    & $addStep 'Master-Key-Kennwort pruefen' 'Blocked' "Oeffnen fehlgeschlagen: $($_.Exception.Message)"
                }
            }

            # ==============================================================
            # 4. Agent-Jobs, die nach dem Umzug umgehaengt werden muessen
            # ==============================================================
            if (-not $SkipAgentJobScan)
            {
                try
                {
                    # SSIS-Steps starten Pakete entweder ueber das SSIS-Subsystem (/ISSERVER ...
                    # /SERVER <alter Server>) oder per T-SQL ueber catalog.create_execution. Beide
                    # Formen zeigen nach dem Umzug weiterhin auf den alten Server.
                    $jobHits = @(Find-sqmAgentJobReference @srcConn -Subsystem 'All' `
                            -SearchText '/ISSERVER|catalog\.(create_execution|start_execution)' -RegexSearch -EnableException)
                    $result.AgentJobsToRepoint = $jobHits
                    if ($jobHits.Count -gt 0)
                    {
                        & $addStep 'Agent-Jobs pruefen' 'Warning' "$($jobHits.Count) Jobstep(s) auf der Quelle starten Pakete aus dem Katalog und muessen nach dem Umzug auf '$DestinationSqlInstance' umgehaengt werden."
                    }
                    else
                    {
                        & $addStep 'Agent-Jobs pruefen' 'Success' 'Kein Agent-Jobstep auf der Quelle startet Pakete aus dem Katalog.'
                    }
                }
                catch
                {
                    & $addStep 'Agent-Jobs pruefen' 'Warning' "Scan nicht moeglich: $($_.Exception.Message)"
                }
            }

            # ==============================================================
            # 5. Bewertung abschliessen / Blocker melden
            # ==============================================================
            if ($blockers.Count -gt 0)
            {
                $result.Status = 'Blocked'
                $result.Reason = ($blockers -join ' | ')
                foreach ($b in $blockers) { & $addStep 'Voraussetzung' 'Blocked' $b }
            }

            if ($AssessOnly)
            {
                if ($result.Status -ne 'Blocked')
                {
                    $result.Status = 'Success'
                    $result.Reason = 'Bewertung abgeschlossen, keine Blocker gefunden.'
                }
                & $addStep 'Bewertung' 'Success' '-AssessOnly: es wurde nichts geaendert.'
            }
            elseif ($result.Status -eq 'Blocked')
            {
                & $addStep 'Migration' 'Blocked' 'Migration nicht gestartet - siehe Blocker.'
            }
            else
            {
                # ==========================================================
                # 6. Master Key sichern
                # ==========================================================
                $keyPwPlain = & $toPlain $(if ($KeyFilePassword) { $KeyFilePassword } else { $CatalogPassword })
                $pwPlain = & $toPlain $CatalogPassword

                $backupDir = $SharedPath
                if (-not $backupDir) { $backupDir = [string]$srcServer.DefaultBackupPath }
                $safeSrcName = $SourceSqlInstance -replace '[\\\/:*?"<>|]', '_'
                $keyFile = Join-Path $backupDir "SSISDB_MasterKey_${safeSrcName}_$timestamp.key"

                if ($PSCmdlet.ShouldProcess($SourceSqlInstance, "Hauptschluessel der SSISDB nach '$keyFile' sichern"))
                {
                    $bkKeySql = "BACKUP MASTER KEY TO FILE = N'$($keyFile -replace "'", "''")' ENCRYPTION BY PASSWORD = N'$($keyPwPlain -replace "'", "''")';"
                    Invoke-DbaQuery @srcConn -Database SSISDB -Query $bkKeySql -EnableException | Out-Null
                    $result.MasterKeyFile = $keyFile
                    & $addStep 'Master Key sichern' 'Success' "Hauptschluessel gesichert nach '$keyFile' (geschrieben vom SQL-Dienstkonto der Quelle)."
                }
                else
                {
                    & $addStep 'Master Key sichern' 'WhatIf' "Wuerde den Hauptschluessel nach '$keyFile' sichern."
                }

                # ==========================================================
                # 7. SSISDB sichern
                # ==========================================================
                $backupFile = $null
                if ($PSCmdlet.ShouldProcess($SourceSqlInstance, "Vollbackup der SSISDB nach '$backupDir'"))
                {
                    $bkParams = @{ Database = 'SSISDB'; Type = 'Full'; CompressBackup = $true; EnableException = $true }
                    if ($SharedPath) { $bkParams['Path'] = $SharedPath }
                    $bk = Backup-DbaDatabase @srcConn @bkParams
                    $backupFile = @($bk.FullName)[0]
                    $result.BackupFile = $backupFile
                    & $addStep 'SSISDB sichern' 'Success' "Vollbackup geschrieben: '$backupFile'."
                }
                else
                {
                    & $addStep 'SSISDB sichern' 'WhatIf' "Wuerde ein Vollbackup der SSISDB nach '$backupDir' schreiben."
                }

                # ==========================================================
                # 8. Ziel vorbereiten: CLR + Katalog
                # ==========================================================
                if (-not $destination.ClrEnabled)
                {
                    if ($PSCmdlet.ShouldProcess($DestinationSqlInstance, "CLR aktivieren (sp_configure 'clr enabled', 1)"))
                    {
                        Invoke-DbaQuery @dstConn -Database master -EnableException -Query @'
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'clr enabled', 1; RECONFIGURE;
'@ | Out-Null
                        $destination.ClrEnabled = $true
                        & $addStep 'CLR aktivieren' 'Success' 'CLR auf dem Ziel aktiviert - ohne CLR laesst sich kein SSIS-Katalog anlegen.'
                    }
                    else
                    {
                        & $addStep 'CLR aktivieren' 'WhatIf' 'Wuerde CLR auf dem Ziel aktivieren.'
                    }
                }
                else
                {
                    & $addStep 'CLR aktivieren' 'Skipped' 'CLR ist auf dem Ziel bereits aktiv.'
                }

                # Der Katalog MUSS vor dem Restore angelegt werden: dabei entstehen die CLR-Assemblies
                # und die SSIS-Objekte ausserhalb der SSISDB (sp_ssis_startup in master, der
                # Wartungsjob im Agent), die ein Datenbank-Restore nicht mitbringt. Gleichzeitig ist
                # die Schemaversion dieses frisch angelegten Katalogs der einzige verlaessliche
                # Massstab dafuer, welche Version dieser Zielserver erzeugt - deshalb wird sie hier
                # gelesen und spaeter mit der wiederhergestellten Version verglichen, statt eine
                # fest verdrahtete Versionstabelle zu pflegen.
                $destinationBaselineSchema = $destination.SchemaVersion
                if (-not $destination.SsisDbExists)
                {
                    if ($PSCmdlet.ShouldProcess($DestinationSqlInstance, 'SSIS-Katalog (SSISDB) anlegen'))
                    {
                        New-DbaSsisCatalog @dstConn -SecurePassword $CatalogPassword -EnableException -Confirm:$false | Out-Null
                        $destination.CatalogCreated = $true

                        $baseSql = "SELECT CAST(property_value AS nvarchar(128)) AS SchemaVersion FROM catalog.catalog_properties WHERE property_name = 'SCHEMA_VERSION'"
                        try
                        {
                            $baseRow = @(Invoke-DbaQuery @dstConn -Database SSISDB -Query $baseSql -EnableException -As PSObject)
                            if ($baseRow.Count -gt 0) { $destinationBaselineSchema = [string]$baseRow[0].SchemaVersion }
                        }
                        catch { }

                        $destination.SchemaVersion = $destinationBaselineSchema
                        $result.SchemaVersionDestination = $destinationBaselineSchema
                        & $addStep 'Katalog anlegen' 'Success' "SSIS-Katalog auf dem Ziel angelegt (Schemaversion dieses Servers: $destinationBaselineSchema)."
                    }
                    else
                    {
                        & $addStep 'Katalog anlegen' 'WhatIf' 'Wuerde den SSIS-Katalog auf dem Ziel anlegen.'
                    }
                }
                else
                {
                    & $addStep 'Katalog anlegen' 'Skipped' "SSISDB ist auf dem Ziel bereits vorhanden (Schemaversion $($destination.SchemaVersion)) - sie wird durch den Restore ueberschrieben (-Force)."
                }

                # ==========================================================
                # 9. SSISDB auf dem Ziel wiederherstellen
                # ==========================================================
                $restoreOk = $false
                if ($backupFile)
                {
                    if ($PSCmdlet.ShouldProcess($DestinationSqlInstance, "SSISDB aus '$backupFile' wiederherstellen (ueberschreibt den eben angelegten Katalog)"))
                    {
                        # Delegiert an Invoke-sqmRestoreDatabase: dort sitzt die erprobte Behandlung
                        # von Exclusive Access (SINGLE_USER, Fremdsessions per Stop-DbaProcess
                        # beenden, Wiederholung). Der frisch angelegte Katalog haelt selbst
                        # Verbindungen offen, deshalb ist das hier kein theoretischer Fall.
                        $restoreParams = @{
                            BackupFile      = $backupFile
                            DatabaseName    = 'SSISDB'
                            ForceSingleUser = $true
                            NoUserExport    = $true
                            Confirm         = $false
                        }
                        if ($DestinationDataPath) { $restoreParams['NewDatabaseFilePath'] = $DestinationDataPath }
                        if ($DestinationLogPath) { $restoreParams['NewLogFilePath'] = $DestinationLogPath }

                        $restoreResult = @(Invoke-sqmRestoreDatabase @dstConn @restoreParams -EnableException:$EnableException)
                        $failedSteps = @($restoreResult | Where-Object { $_.Status -eq 'Failed' })
                        $restoreOk = ($failedSteps.Count -eq 0 -and @($restoreResult | Where-Object { $_.Action -eq 'RestoreStep' -and $_.Status -eq 'Success' }).Count -gt 0)

                        if ($restoreOk)
                        {
                            & $addStep 'SSISDB wiederherstellen' 'Success' "SSISDB auf '$DestinationSqlInstance' aus '$backupFile' wiederhergestellt."
                        }
                        else
                        {
                            $detail = ($failedSteps | ForEach-Object { $_.Message }) -join ' | '
                            if (-not $detail) { $detail = 'Kein erfolgreicher Restore-Schritt im Ergebnis.' }
                            & $addStep 'SSISDB wiederherstellen' 'Failed' $detail
                            $result.Status = 'Failed'
                            $result.Reason = "Restore der SSISDB fehlgeschlagen: $detail"
                        }
                    }
                    else
                    {
                        & $addStep 'SSISDB wiederherstellen' 'WhatIf' "Wuerde SSISDB aus '$backupFile' auf '$DestinationSqlInstance' wiederherstellen."
                    }
                }
                else
                {
                    & $addStep 'SSISDB wiederherstellen' 'WhatIf' 'Ohne Backupdatei (WhatIf-Lauf) wird nichts wiederhergestellt.'
                }

                # ==========================================================
                # 10. Nacharbeit auf dem Ziel
                # ==========================================================
                if ($restoreOk)
                {
                    # 10a. TRUSTWORTHY und Eigentuemer. Beides geht beim Restore verloren: SQL Server
                    #      setzt TRUSTWORTHY grundsaetzlich auf OFF und macht den wiederherstellenden
                    #      Login zum Eigentuemer. SSISDB braucht beides, sonst scheitern die
                    #      CLR-Aufrufe des Katalogs.
                    if ($PSCmdlet.ShouldProcess($DestinationSqlInstance, 'SSISDB: TRUSTWORTHY ON und Eigentuemer sa setzen'))
                    {
                        Invoke-DbaQuery @dstConn -Database master -EnableException -Query @'
ALTER DATABASE SSISDB SET TRUSTWORTHY ON;
ALTER AUTHORIZATION ON DATABASE::SSISDB TO sa;
'@ | Out-Null
                        & $addStep 'TRUSTWORTHY/Eigentuemer' 'Success' 'TRUSTWORTHY ON gesetzt und Eigentuemer auf sa zurueckgesetzt.'
                    }

                    # 10b. Umschluesseln. Der wiederhergestellte Hauptschluessel traegt noch die
                    #      Verschluesselung durch den Service Master Key des ALTEN Servers, die der
                    #      neue Server nicht entschluesseln kann. Auf einem echten SQL Server
                    #      nachgestellt und geprueft: nach Wegfall der Dienstschluessel-Verschluesselung
                    #      steht is_master_key_encrypted_by_server auf 0, und genau die Folge
                    #      OPEN ... / ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY setzt sie
                    #      wieder auf 1.
                    if ($PSCmdlet.ShouldProcess($DestinationSqlInstance, 'SSISDB-Hauptschluessel auf den Service Master Key des Ziels umschluesseln'))
                    {
                        $rekeyOk = $false
                        if ($UseKeyBackupRestore)
                        {
                            if (-not $Force)
                            {
                                & $addStep 'Master Key umschluesseln' 'Failed' 'RESTORE MASTER KEY ueber einen vorhandenen Hauptschluessel verlangt FORCE, und FORCE macht alles unlesbar, was der alte Schluessel noch schuetzt. Lauf mit -Force wiederholen, wenn das gewollt ist.'
                            }
                            else
                            {
                                $restoreKeySql = "RESTORE MASTER KEY FROM FILE = N'$($keyFile -replace "'", "''")' DECRYPTION BY PASSWORD = N'$($keyPwPlain -replace "'", "''")' ENCRYPTION BY PASSWORD = N'$($pwPlain -replace "'", "''")' FORCE;"
                                try
                                {
                                    Invoke-DbaQuery @dstConn -Database SSISDB -Query $restoreKeySql -EnableException | Out-Null
                                    # RESTORE MASTER KEY allein reicht NICHT: der wiederhergestellte
                                    # Schluessel ist danach nur durch das Kennwort geschuetzt
                                    # (is_master_key_encrypted_by_server = 0, auf einem echten Server
                                    # nachgemessen). Die Dienstschluessel-Verschluesselung muss
                                    # anschliessend explizit ergaenzt werden, sonst verlangt SSIS bei
                                    # jedem Zugriff das Kennwort.
                                    Invoke-DbaQuery @dstConn -Database SSISDB -EnableException -Query @"
OPEN MASTER KEY DECRYPTION BY PASSWORD = N'$($pwPlain -replace "'", "''")';
ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY;
CLOSE MASTER KEY;
"@ | Out-Null
                                    $rekeyOk = $true
                                    & $addStep 'Master Key umschluesseln' 'Success' 'Hauptschluessel aus der Sicherungsdatei wiederhergestellt und um die Verschluesselung durch den Service Master Key ergaenzt.'
                                }
                                catch
                                {
                                    & $addStep 'Master Key umschluesseln' 'Failed' "RESTORE MASTER KEY fehlgeschlagen: $($_.Exception.Message)"
                                }
                            }
                        }
                        else
                        {
                            try
                            {
                                Invoke-DbaQuery @dstConn -Database SSISDB -EnableException -Query @"
OPEN MASTER KEY DECRYPTION BY PASSWORD = N'$($pwPlain -replace "'", "''")';
ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY;
CLOSE MASTER KEY;
"@ | Out-Null
                                $rekeyOk = $true
                            }
                            catch
                            {
                                # Eine stehengebliebene, nicht entschluesselbare Verschluesselung durch
                                # den alten Dienstschluessel kann das ADD blockieren. Dann zuerst die
                                # alte Verschluesselung entfernen und erneut ergaenzen.
                                & $addStep 'Master Key umschluesseln' 'Warning' "Direktes ADD ENCRYPTION fehlgeschlagen ($($_.Exception.Message)) - versuche, die alte Dienstschluessel-Verschluesselung zuerst zu entfernen."
                                try
                                {
                                    Invoke-DbaQuery @dstConn -Database SSISDB -EnableException -Query @"
OPEN MASTER KEY DECRYPTION BY PASSWORD = N'$($pwPlain -replace "'", "''")';
ALTER MASTER KEY DROP ENCRYPTION BY SERVICE MASTER KEY;
ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY;
CLOSE MASTER KEY;
"@ | Out-Null
                                    $rekeyOk = $true
                                }
                                catch
                                {
                                    & $addStep 'Master Key umschluesseln' 'Failed' "Umschluesseln fehlgeschlagen: $($_.Exception.Message)"
                                }
                            }
                        }

                        if ($rekeyOk)
                        {
                            # Nicht dem Rueckgabewert vertrauen, sondern den Zustand nachlesen.
                            $keyState = @(Invoke-DbaQuery @dstConn -Database master -EnableException -As PSObject `
                                    -Query "SELECT is_master_key_encrypted_by_server AS ByService FROM sys.databases WHERE name = 'SSISDB'")
                            $byService = ($keyState.Count -gt 0 -and [bool]$keyState[0].ByService)
                            if ($byService)
                            {
                                & $addStep 'Master Key umschluesseln' 'Success' 'Der Hauptschluessel ist jetzt durch den Service Master Key des Ziels verschluesselt (is_master_key_encrypted_by_server = 1).'
                            }
                            else
                            {
                                & $addStep 'Master Key umschluesseln' 'Failed' 'Die Anweisungen liefen ohne Fehler, is_master_key_encrypted_by_server steht aber weiterhin auf 0 - SSIS wuerde bei jedem Zugriff das Kennwort verlangen.'
                            }
                        }
                    }

                    # 10c. catalog.startup: raeumt Operationen auf, die beim Wegfall der alten Instanz
                    #      im Status "laeuft" stehen geblieben sind. Ohne diesen Aufruf zeigt der neue
                    #      Katalog Ausfuehrungen als laufend an, die es nicht mehr gibt.
                    if ($PSCmdlet.ShouldProcess($DestinationSqlInstance, 'EXEC catalog.startup'))
                    {
                        try
                        {
                            Invoke-DbaQuery @dstConn -Database SSISDB -Query 'EXEC catalog.startup;' -EnableException | Out-Null
                            & $addStep 'catalog.startup' 'Success' 'Operationsstatus des Katalogs bereinigt.'
                        }
                        catch
                        {
                            & $addStep 'catalog.startup' 'Failed' "catalog.startup fehlgeschlagen: $($_.Exception.Message). Das ist der erste Punkt, an dem sich ein nicht umgeschluesselter Hauptschluessel zeigt."
                        }
                    }

                    # 10d. Verwaiste Benutzer. Die SSISDB-Rollen (ssis_admin, ssis_logreader) haengen
                    #      an Datenbankbenutzern, deren SIDs auf dem Ziel andere Logins meinen.
                    if ($PSCmdlet.ShouldProcess($DestinationSqlInstance, 'Verwaiste Benutzer in SSISDB neu zuordnen'))
                    {
                        try
                        {
                            $orphans = @(Repair-DbaDbOrphanUser @dstConn -Database SSISDB -EnableException)
                            & $addStep 'Verwaiste Benutzer' 'Success' "$($orphans.Count) verwaiste(r) Benutzer in SSISDB neu zugeordnet."
                        }
                        catch
                        {
                            & $addStep 'Verwaiste Benutzer' 'Warning' "Neuzuordnung nicht moeglich: $($_.Exception.Message)"
                        }
                    }

                    # ======================================================
                    # 11. Schemaversion vergleichen und ggf. anheben
                    # ======================================================
                    $restoredSchema = $null
                    try
                    {
                        $rs = @(Invoke-DbaQuery @dstConn -Database SSISDB -EnableException -As PSObject `
                                -Query "SELECT CAST(property_value AS nvarchar(128)) AS SchemaVersion FROM catalog.catalog_properties WHERE property_name = 'SCHEMA_VERSION'")
                        if ($rs.Count -gt 0) { $restoredSchema = [string]$rs[0].SchemaVersion }
                    }
                    catch
                    {
                        & $addStep 'Schemaversion pruefen' 'Warning' "Schemaversion nach dem Restore nicht lesbar: $($_.Exception.Message)"
                    }

                    $result.SchemaVersionDestination = $restoredSchema
                    $upgradeNeeded = $false
                    if ($restoredSchema -and $destinationBaselineSchema)
                    {
                        $a = 0; $b = 0
                        if ([int]::TryParse($restoredSchema, [ref]$a) -and [int]::TryParse($destinationBaselineSchema, [ref]$b))
                        {
                            $upgradeNeeded = ($a -lt $b)
                        }
                        else
                        {
                            $upgradeNeeded = ($restoredSchema -ne $destinationBaselineSchema)
                        }
                    }
                    $result.UpgradeRequired = $upgradeNeeded

                    if (-not $upgradeNeeded)
                    {
                        & $addStep 'Schemaversion pruefen' 'Success' "Schemaversion $restoredSchema entspricht dem, was '$DestinationSqlInstance' selbst erzeugt - kein Upgrade noetig."
                    }
                    elseif (-not $UpgradeCatalog)
                    {
                        & $addStep 'Schemaversion pruefen' 'Warning' "Der wiederhergestellte Katalog steht auf Schemaversion $restoredSchema, dieser Server erzeugt $destinationBaselineSchema. Ein Upgrade ist noetig - Lauf mit -UpgradeCatalog wiederholen oder in SSMS ueber 'Integration Services Catalogs / SSISDB / Upgrade...' anstossen."
                    }
                    else
                    {
                        $wizard = $UpgradeWizardPath
                        if (-not $wizard)
                        {
                            # Hoechste vorhandene Version gewinnt: der Assistent des neueren
                            # Servers kann aeltere Kataloge anheben, umgekehrt nicht.
                            $candidates = @(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'Microsoft SQL Server') -Filter 'ISDBUpgradeWizard.exe' -Recurse -ErrorAction SilentlyContinue |
                                Sort-Object FullName -Descending)
                            if ($candidates.Count -gt 0) { $wizard = $candidates[0].FullName }
                        }

                        if (-not $wizard -or -not (Test-Path $wizard))
                        {
                            $result.UpgradeResult = 'WizardNotFound'
                            & $addStep 'Katalog-Upgrade' 'Warning' "ISDBUpgradeWizard.exe wurde auf diesem Rechner nicht gefunden. Upgrade auf dem Zielserver ausfuehren oder Pfad mit -UpgradeWizardPath angeben; alternativ in SSMS ueber 'Integration Services Catalogs / SSISDB / Upgrade...'."
                        }
                        elseif ($PSCmdlet.ShouldProcess($DestinationSqlInstance, "Katalog-Upgrade mit '$wizard'"))
                        {
                            $wizardArgs = $UpgradeWizardArgument
                            if (-not $wizardArgs) { $wizardArgs = @('-S', $DestinationSqlInstance, '-q') }
                            try
                            {
                                $proc = Start-Process -FilePath $wizard -ArgumentList $wizardArgs -Wait -PassThru -NoNewWindow -ErrorAction Stop
                                # Nicht dem Exitcode vertrauen: massgeblich ist, ob die Schemaversion
                                # danach tatsaechlich steht. Ein falscher Aufrufparameter faellt so als
                                # "Upgrade ohne Wirkung" auf statt als vermeintlicher Erfolg.
                                $after = $null
                                try
                                {
                                    $ra = @(Invoke-DbaQuery @dstConn -Database SSISDB -EnableException -As PSObject `
                                            -Query "SELECT CAST(property_value AS nvarchar(128)) AS SchemaVersion FROM catalog.catalog_properties WHERE property_name = 'SCHEMA_VERSION'")
                                    if ($ra.Count -gt 0) { $after = [string]$ra[0].SchemaVersion }
                                }
                                catch { }

                                $result.SchemaVersionDestination = $after
                                if ($after -and $after -eq $destinationBaselineSchema)
                                {
                                    $result.UpgradeResult = 'Success'
                                    $result.UpgradeRequired = $false
                                    & $addStep 'Katalog-Upgrade' 'Success' "Schemaversion nach dem Upgrade: $after (Exitcode $($proc.ExitCode))."
                                }
                                else
                                {
                                    $result.UpgradeResult = 'NoEffect'
                                    & $addStep 'Katalog-Upgrade' 'Failed' "Der Assistent lief (Exitcode $($proc.ExitCode)), die Schemaversion steht aber weiterhin auf '$after' statt '$destinationBaselineSchema'. Aufrufparameter pruefen (-UpgradeWizardArgument) oder das Upgrade in SSMS anstossen."
                                }
                            }
                            catch
                            {
                                $result.UpgradeResult = 'Failed'
                                & $addStep 'Katalog-Upgrade' 'Failed' "Aufruf von '$wizard' fehlgeschlagen: $($_.Exception.Message)"
                            }
                        }
                    }
                }

                if ($result.Status -eq 'Unknown')
                {
                    $failed = @($steps | Where-Object { $_.Status -eq 'Failed' })
                    if ($failed.Count -gt 0)
                    {
                        $result.Status = 'Failed'
                        $result.Reason = ($failed | ForEach-Object { $_.Step }) -join ', '
                    }
                    elseif (@($steps | Where-Object { $_.Status -eq 'WhatIf' }).Count -gt 0)
                    {
                        $result.Status = 'WhatIf'
                        $result.Reason = 'WhatIf-Lauf, es wurde nichts geaendert.'
                    }
                    else
                    {
                        $result.Status = 'Success'
                        $result.Reason = "Katalog von '$SourceSqlInstance' nach '$DestinationSqlInstance' migriert."
                    }
                }
            }

            if ($result.Status -eq 'Unknown') { $result.Status = 'Success' }

            # ==============================================================
            # 12. Bericht
            # ==============================================================
            if (-not $NoReport)
            {
                try
                {
                    if (-not (Test-Path $OutputPath))
                    {
                        $null = New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop
                    }
                    $reportFile = Join-Path $OutputPath "SsisCatalogMigration_$timestamp.html"
                    $bodyHtml = & $buildReportBody $result $steps
                    $html = ConvertTo-sqmHtmlReport -Title 'SSIS-Katalog-Migration' `
                        -Subtitle "$SourceSqlInstance  ->  $DestinationSqlInstance   ($($result.Action), Status: $($result.Status))" `
                        -BodyHtml $bodyHtml
                    [System.IO.File]::WriteAllText($reportFile, $html, [System.Text.UTF8Encoding]::new($false))
                    $result.ReportFile = $reportFile
                    Invoke-sqmOpenReport -HtmlFile $reportFile -NoOpen:$NoOpen
                }
                catch
                {
                    Invoke-sqmLogging -Message "Bericht konnte nicht geschrieben werden: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
                }
            }

            return $result
        }
        catch
        {
            $result.Status = 'Failed'
            $result.Reason = $_.Exception.Message
            & $addStep 'Abbruch' 'Failed' $_.Exception.Message
            Invoke-sqmLogging -Message $_.Exception.Message -FunctionName $functionName -Level "ERROR"
            if ($EnableException) { throw }
            return $result
        }
    }
}
