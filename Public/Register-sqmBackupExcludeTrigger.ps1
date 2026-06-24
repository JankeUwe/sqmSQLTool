<#
.SYNOPSIS
    Registriert oder entfernt den DDL-Trigger, der master.dbo.sqm_BackupExclude
    automatisch bei CREATE_DATABASE und DROP_DATABASE aktuell haelt.

.DESCRIPTION
    Legt einen server-weiten DDL-Trigger (ON ALL SERVER) an, der feuert bei:
      CREATE_DATABASE — fuegt neue Datenbank in sqm_BackupExclude ein (IsActive=1, IsOrphaned=0).
                        Reaktiviert einen ggf. bereits als verwaist markierten Eintrag.
      DROP_DATABASE   — markiert die Datenbank in sqm_BackupExclude als IsOrphaned=1.

    Damit entfaellt die Notwendigkeit, nach Datenbank-Anlage oder -Loeschung manuell
    Sync-sqmBackupExcludeTable aufzurufen — die Tabelle ist immer aktuell.

    Verhalten:
      - tempdb wird immer uebersprungen.
      - Systemdatenbanken (master, model, msdb) werden uebersprungen, ausser
        -IncludeSystemDatabases ist gesetzt.
      - Fehler im Trigger brechen CREATE DATABASE / DROP DATABASE nie ab;
        sie werden ins SQL Server Error Log geschrieben.
      - Existiert master.dbo.sqm_BackupExclude noch nicht, protokolliert der
        Trigger eine Warnung und beendet sich sauber.

    In AlwaysOn-Umgebungen wird der Trigger automatisch auf allen Secondary-Repliken
    registriert, sofern -SkipAlwaysOnPropagation nicht gesetzt ist.

    Mit -Remove wird der Trigger geloescht (inkl. Secondaries).

    Triggername: trg_sqm_BackupExclude_AutoSync

.PARAMETER SqlInstance
    SQL Server-Instanz. Standard: $env:COMPUTERNAME.

.PARAMETER SqlCredential
    PSCredential fuer SQL-Authentifizierung. Standard: Windows-Auth.

.PARAMETER IncludeSystemDatabases
    Wenn gesetzt, werden auch master, model und msdb automatisch verwaltet.
    Fuer Standardinstallationen nicht empfohlen.

.PARAMETER Remove
    Entfernt den Trigger (auf Primary und ggf. Secondaries).

.PARAMETER SkipAlwaysOnPropagation
    Verhindert die automatische Propagierung auf AlwaysOn-Secondaries.

.PARAMETER EnableException
    Loest bei Fehlern sofort eine Exception aus statt Write-Error.

.OUTPUTS
    PSCustomObject: SqlInstance, TriggerName, Action, Message

.EXAMPLE
    Register-sqmBackupExcludeTrigger

.EXAMPLE
    Register-sqmBackupExcludeTrigger -SqlInstance "SQL01"

.EXAMPLE
    Register-sqmBackupExcludeTrigger -SqlInstance "SQL01" -Remove
    Register-sqmBackupExcludeTrigger -SqlInstance "SQL01"

.EXAMPLE
    Register-sqmBackupExcludeTrigger -SqlInstance "SQL01" -WhatIf

.NOTES
    Voraussetzung: dbatools, master.dbo.sqm_BackupExclude muss existieren
                   (Sync-sqmBackupExcludeTable zuerst ausfuehren).
    Berechtigungen: sysadmin oder ALTER ANY DATABASE + VIEW SERVER STATE.
#>
function Register-sqmBackupExcludeTrigger
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$SqlInstance,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeSystemDatabases,

        [Parameter(Mandatory = $false)]
        [switch]$Remove,

        [Parameter(Mandatory = $false)]
        [switch]$SkipAlwaysOnPropagation,

        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin
    {
        $functionName = $MyInvocation.MyCommand.Name
        $triggerName  = 'trg_sqm_BackupExclude_AutoSync'

        if (-not $PSBoundParameters.ContainsKey('SqlInstance') -or [string]::IsNullOrWhiteSpace($SqlInstance))
        {
            $SqlInstance = $env:COMPUTERNAME
        }

        if (-not (Get-Module -ListAvailable -Name dbatools))
        {
            $errMsg = "dbatools-Modul nicht gefunden. Bitte installieren: Install-Module dbatools"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
            throw $errMsg
        }

        $connParams = @{ SqlInstance = $SqlInstance }
        if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

        # Systemdatenbanken die der Trigger immer ueberspringen soll
        $skipListSql = if ($IncludeSystemDatabases) { "N'tempdb'" }
                       else                         { "N'tempdb', N'master', N'model', N'msdb'" }

        $dropSql = @"
IF EXISTS (SELECT 1 FROM sys.server_triggers WHERE name = N'$triggerName')
    DROP TRIGGER [$triggerName] ON ALL SERVER;
"@

        $createSql = @"
CREATE TRIGGER [$triggerName]
ON ALL SERVER
AFTER CREATE_DATABASE, DROP_DATABASE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @dbName    sysname;
    DECLARE @eventType nvarchar(100);

    SELECT @dbName    = EVENTDATA().value('(/EVENT_INSTANCE/DatabaseName)[1]', 'sysname');
    SELECT @eventType = EVENTDATA().value('(/EVENT_INSTANCE/EventType)[1]',   'nvarchar(100)');

    -- tempdb und ggf. Systemdatenbanken immer ueberspringen
    IF @dbName IN ($skipListSql)
        RETURN;

    BEGIN TRY
        -- Sicherheitscheck: Tabelle muss existieren
        IF NOT EXISTS (
            SELECT 1 FROM master.sys.objects
            WHERE object_id = OBJECT_ID(N'master.dbo.sqm_BackupExclude') AND type = 'U'
        )
        BEGIN
            RAISERROR(
                'sqmSQLTool: master.dbo.sqm_BackupExclude nicht gefunden. Bitte Sync-sqmBackupExcludeTable ausfuehren.',
                10, 1) WITH LOG;
            RETURN;
        END

        IF @eventType = 'CREATE_DATABASE'
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM master.dbo.sqm_BackupExclude WHERE DatabaseName = @dbName)
            BEGIN
                INSERT INTO master.dbo.sqm_BackupExclude (DatabaseName, IsActive, IsOrphaned)
                VALUES (@dbName, 1, 0);
            END
            ELSE
            BEGIN
                -- Eintrag war als verwaist markiert — reaktivieren
                UPDATE master.dbo.sqm_BackupExclude
                SET    IsOrphaned = 0
                WHERE  DatabaseName = @dbName
                  AND  IsOrphaned   = 1;
            END
        END
        ELSE IF @eventType = 'DROP_DATABASE'
        BEGIN
            UPDATE master.dbo.sqm_BackupExclude
            SET    IsOrphaned = 1
            WHERE  DatabaseName = @dbName
              AND  IsOrphaned   = 0;
        END
    END TRY
    BEGIN CATCH
        DECLARE @msg nvarchar(2048) =
            N'sqmSQLTool DDL-Trigger Fehler fuer "' + ISNULL(@dbName, '?') +
            N'" (' + ISNULL(@eventType, '?') + N'): ' + ERROR_MESSAGE();
        RAISERROR(@msg, 10, 1) WITH LOG;
    END CATCH
END
"@
    }

    process
    {
        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        try
        {
            Invoke-sqmLogging -Message "[$SqlInstance] Starte $functionName (Remove=$Remove)" -FunctionName $functionName -Level 'INFO'

            $triggerExists = Invoke-DbaQuery @connParams `
                -Query "SELECT 1 AS Found FROM sys.server_triggers WHERE name = N'$triggerName'" `
                -ErrorAction Stop

            # ── REMOVE ───────────────────────────────────────────────────────────
            if ($Remove)
            {
                if (-not $triggerExists)
                {
                    $msg = "Trigger '$triggerName' ist auf '$SqlInstance' nicht vorhanden."
                    Invoke-sqmLogging -Message "[$SqlInstance] $msg" -FunctionName $functionName -Level 'WARNING'
                    Write-Warning $msg
                    $results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; TriggerName = $triggerName; Action = 'NotFound'; Message = $msg })
                }
                elseif ($PSCmdlet.ShouldProcess($SqlInstance, "Loesche DDL-Trigger '$triggerName'"))
                {
                    Invoke-DbaQuery @connParams -Query $dropSql -ErrorAction Stop
                    $msg = "Trigger '$triggerName' wurde von '$SqlInstance' entfernt."
                    Invoke-sqmLogging -Message "[$SqlInstance] $msg" -FunctionName $functionName -Level 'INFO'
                    $results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; TriggerName = $triggerName; Action = 'Removed'; Message = $msg })
                }
                else
                {
                    $results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; TriggerName = $triggerName; Action = 'WhatIfSkipped'; Message = "WhatIf: Trigger '$triggerName' wuerde entfernt werden." })
                }
            }
            # ── CREATE ───────────────────────────────────────────────────────────
            else
            {
                if ($triggerExists)
                {
                    $msg = "Trigger '$triggerName' existiert bereits auf '$SqlInstance'. Keine Aenderung. Zum Aktualisieren: -Remove dann erneut aufrufen."
                    Invoke-sqmLogging -Message "[$SqlInstance] $msg" -FunctionName $functionName -Level 'INFO'
                    $results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; TriggerName = $triggerName; Action = 'AlreadyExists'; Message = $msg })
                }
                else
                {
                    # Zieltabelle muss vorhanden sein
                    $tableExists = Invoke-DbaQuery @connParams `
                        -Query "SELECT 1 AS Found FROM master.sys.objects WHERE object_id = OBJECT_ID(N'master.dbo.sqm_BackupExclude') AND type = 'U'" `
                        -ErrorAction Stop

                    if (-not $tableExists)
                    {
                        $errMsg = "master.dbo.sqm_BackupExclude nicht gefunden auf '$SqlInstance'. Bitte zuerst Sync-sqmBackupExcludeTable ausfuehren."
                        Invoke-sqmLogging -Message "[$SqlInstance] $errMsg" -FunctionName $functionName -Level 'ERROR'
                        if ($EnableException) { throw $errMsg }
                        Write-Error $errMsg
                        $results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; TriggerName = $triggerName; Action = 'Error'; Message = $errMsg })
                    }
                    elseif ($PSCmdlet.ShouldProcess($SqlInstance, "Erstelle DDL-Trigger '$triggerName' (CREATE_DATABASE + DROP_DATABASE)"))
                    {
                        Invoke-DbaQuery @connParams -Query $createSql -ErrorAction Stop
                        $msg = "DDL-Trigger '$triggerName' erfolgreich registriert auf '$SqlInstance' (CREATE_DATABASE + DROP_DATABASE)."
                        Invoke-sqmLogging -Message "[$SqlInstance] $msg" -FunctionName $functionName -Level 'INFO'
                        $results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; TriggerName = $triggerName; Action = 'Created'; Message = $msg })
                    }
                    else
                    {
                        $results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; TriggerName = $triggerName; Action = 'WhatIfSkipped'; Message = "WhatIf: Trigger '$triggerName' wuerde erstellt werden." })
                    }
                }
            }
        }
        catch
        {
            $errMsg = "Fehler in $functionName auf '$SqlInstance': $($_.Exception.Message)"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
            if ($EnableException) { throw }
            Write-Error $errMsg
            $results.Add([PSCustomObject]@{ SqlInstance = $SqlInstance; TriggerName = $triggerName; Action = 'Error'; Message = $errMsg })
        }

        # AlwaysOn-Propagierung: Trigger auch auf Secondary-Repliken registrieren
        if (-not $SkipAlwaysOnPropagation -and ($results | Where-Object { $_.Action -in 'Created','Removed','AlreadyExists' }))
        {
            try
            {
                $replicaQuery = "SELECT r.replica_server_name FROM sys.availability_replicas r WHERE r.replica_server_name <> @@SERVERNAME"
                $secondaries = Invoke-DbaQuery @connParams -Database master -Query $replicaQuery -ErrorAction SilentlyContinue

                foreach ($sec in $secondaries)
                {
                    $secName = $sec.replica_server_name
                    Invoke-sqmLogging -Message "AlwaysOn: Propagiere Trigger auf Secondary '$secName'." -FunctionName $functionName -Level 'INFO'
                    try
                    {
                        $secParams = @{ SqlInstance = $secName; SkipAlwaysOnPropagation = $true }
                        if ($SqlCredential)          { $secParams['SqlCredential']          = $SqlCredential }
                        if ($IncludeSystemDatabases) { $secParams['IncludeSystemDatabases'] = $true }
                        if ($Remove)                 { $secParams['Remove']                 = $true }

                        $secResult = Register-sqmBackupExcludeTrigger @secParams
                        Invoke-sqmLogging -Message "AlwaysOn '$secName': $($secResult.Action) — $($secResult.Message)" -FunctionName $functionName -Level 'INFO'
                        $results.Add([PSCustomObject]@{
                            SqlInstance = $secName
                            TriggerName = $triggerName
                            Action      = "Secondary_$($secResult.Action)"
                            Message     = "[AlwaysOn Secondary '$secName'] $($secResult.Message)"
                        })
                    }
                    catch
                    {
                        Invoke-sqmLogging -Message "AlwaysOn: Fehler bei Propagierung auf '$secName': $($_.Exception.Message)" -FunctionName $functionName -Level 'WARNING'
                    }
                }
            }
            catch
            {
                Invoke-sqmLogging -Message "AlwaysOn-Erkennung nicht verfuegbar oder kein AG konfiguriert." -FunctionName $functionName -Level 'VERBOSE'
            }
        }

        return $results.ToArray()
    }

    end
    {
        Invoke-sqmLogging -Message "[$SqlInstance] $functionName abgeschlossen." -FunctionName $functionName -Level 'INFO'
    }
}
