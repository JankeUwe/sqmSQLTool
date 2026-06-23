<#
.SYNOPSIS
    Registriert oder entfernt den DDL-Trigger, der neue Datenbanken automatisch in
    master.dbo.sqm_BackupExclude aufnimmt.

.DESCRIPTION
    Legt einen server-weiten DDL-Trigger (ON ALL SERVER, AFTER CREATE_DATABASE) an,
    der bei jeder neu erstellten Datenbank einen Eintrag in master.dbo.sqm_BackupExclude
    einfuegt (IsActive=1, IsOrphaned=0).

    Damit entfaellt die Notwendigkeit, nach dem Anlegen neuer Datenbanken manuell
    Sync-sqmBackupExcludeTable aufzurufen - die Tabelle ist immer aktuell.

    Verhalten des Triggers:
      - tempdb wird immer uebersprungen.
      - Systemdatenbanken (master, model, msdb) werden uebersprungen, ausser
        -IncludeSystemDatabases ist gesetzt.
      - Existiert die Zieltabelle noch nicht, protokolliert der Trigger einen Fehler
        in das SQL Server Error Log und beendet sich sauber (kein Abbruch von CREATE DATABASE).
      - Ein bereits vorhandener Eintrag in der Tabelle wird nicht doppelt eingefuegt.
      - Der Trigger laeuft im Sicherheitskontext des Aufrufers von CREATE DATABASE,
        der mindestens die Rolle dbcreator oder sysadmin haben muss (sonst haette er
        CREATE DATABASE gar nicht ausfuehren koennen).

    Mit -Remove wird der Trigger geloescht.

    Triggername: trg_sqm_BackupExclude_AutoAdd

.PARAMETER SqlInstance
    SQL Server-Instanz. Standard: aktueller Computername ($env:COMPUTERNAME).

.PARAMETER SqlCredential
    Optionale PSCredential fuer SQL-Authentifizierung. Standard: Windows-Auth.

.PARAMETER IncludeSystemDatabases
    Wenn gesetzt, werden auch master, model und msdb automatisch eingetragen,
    wenn sie (neu) erstellt werden. Fuer Standardinstallationen nicht empfohlen.

.PARAMETER Remove
    Entfernt den Trigger, falls er existiert.

.PARAMETER EnableException
    Loest bei Fehlern sofort eine Exception aus statt Write-Error.

.OUTPUTS
    PSCustomObject:
    - SqlInstance  : Ziel-Instanz
    - TriggerName  : trg_sqm_BackupExclude_AutoAdd
    - Action       : Created | AlreadyExists | Removed | NotFound | Error
    - Message      : Beschreibung des Ergebnisses

.EXAMPLE
    # Trigger auf lokaler Instanz anlegen
    Register-sqmBackupExcludeTrigger

.EXAMPLE
    # Trigger auf Remote-Instanz anlegen
    Register-sqmBackupExcludeTrigger -SqlInstance "SQL01"

.EXAMPLE
    # Vorhandenen Trigger zunaechst entfernen, dann neu anlegen (Update)
    Register-sqmBackupExcludeTrigger -SqlInstance "SQL01" -Remove
    Register-sqmBackupExcludeTrigger -SqlInstance "SQL01"

.EXAMPLE
    # Trigger entfernen
    Register-sqmBackupExcludeTrigger -SqlInstance "SQL01" -Remove

.EXAMPLE
    # Vorschau ohne tatsaechliche Aenderung
    Register-sqmBackupExcludeTrigger -SqlInstance "SQL01" -WhatIf

.NOTES
    Author:       sqmSQLTool
    Voraussetzung: dbatools, master.dbo.sqm_BackupExclude muss existieren
                   (Sync-sqmBackupExcludeTable zuerst ausfuehren).
    Berechtigungen: sysadmin oder ALTER ANY DATABASE + VIEW SERVER STATE auf der Instanz.
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
        [switch]$EnableException
    )

    begin
    {
        $functionName  = $MyInvocation.MyCommand.Name
        $triggerName   = 'trg_sqm_BackupExclude_AutoAdd'

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
        # (comma-separated fuer IN-Klausel im T-SQL)
        $skipListSql = if ($IncludeSystemDatabases)
        {
            "N'tempdb'"
        }
        else
        {
            "N'tempdb', N'master', N'model', N'msdb'"
        }

        $dropSql = @"
IF EXISTS (
    SELECT 1 FROM sys.server_triggers
    WHERE name = N'$triggerName'
)
    DROP TRIGGER [$triggerName] ON ALL SERVER;
"@

        # T-SQL fuer den DDL-Trigger.
        # Der Trigger liest den Datenbanknamen aus EVENTDATA() und fuegt ihn ein,
        # sofern die Zieltabelle vorhanden und der Name noch nicht enthalten ist.
        # Fehler werden ins SQL Error Log geschrieben, brechen CREATE DATABASE nie ab.
        $createSql = @"
CREATE TRIGGER [$triggerName]
ON ALL SERVER
AFTER CREATE_DATABASE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @dbName sysname;
    SELECT @dbName = EVENTDATA().value(
        '(/EVENT_INSTANCE/DatabaseName)[1]', 'sysname');

    -- Ueberspringe tempdb und ggf. Systemdatenbanken
    IF @dbName IN ($skipListSql)
        RETURN;

    BEGIN TRY
        -- Sicherheitscheck: Tabelle muss existieren
        IF NOT EXISTS (
            SELECT 1 FROM master.sys.objects
            WHERE object_id = OBJECT_ID(N'master.dbo.sqm_BackupExclude')
              AND type = 'U'
        )
        BEGIN
            RAISERROR(
                'sqmSQLTool: master.dbo.sqm_BackupExclude nicht gefunden. Bitte Sync-sqmBackupExcludeTable ausfuehren.',
                10, 1) WITH LOG;
            RETURN;
        END

        -- Einfuegen, falls noch kein Eintrag vorhanden
        IF NOT EXISTS (
            SELECT 1 FROM master.dbo.sqm_BackupExclude
            WHERE DatabaseName = @dbName
        )
        BEGIN
            INSERT INTO master.dbo.sqm_BackupExclude
                (DatabaseName, IsActive, IsOrphaned)
            VALUES
                (@dbName, 1, 0);
        END
    END TRY
    BEGIN CATCH
        -- Fehler protokollieren, aber CREATE DATABASE nicht abbrechen
        DECLARE @msg nvarchar(2048) =
            N'sqmSQLTool DDL-Trigger: Fehler beim Eintragen von "' + @dbName +
            N'" in sqm_BackupExclude: ' + ERROR_MESSAGE();
        RAISERROR(@msg, 10, 1) WITH LOG;
    END CATCH
END
"@
    }

    process
    {
        try
        {
            Invoke-sqmLogging -Message "[$SqlInstance] Starte $functionName (Remove=$Remove)" -FunctionName $functionName -Level 'INFO'

            $triggerExists = Invoke-DbaQuery @connParams `
                -Query "SELECT 1 AS Exists FROM sys.server_triggers WHERE name = N'$triggerName'" `
                -ErrorAction Stop

            # ── REMOVE ───────────────────────────────────────────────────────
            if ($Remove)
            {
                if (-not $triggerExists)
                {
                    $msg = "Trigger '$triggerName' ist auf '$SqlInstance' nicht vorhanden."
                    Invoke-sqmLogging -Message "[$SqlInstance] $msg" -FunctionName $functionName -Level 'WARNING'
                    Write-Warning $msg
                    return [PSCustomObject]@{
                        SqlInstance = $SqlInstance
                        TriggerName = $triggerName
                        Action      = 'NotFound'
                        Message     = $msg
                    }
                }

                if ($PSCmdlet.ShouldProcess($SqlInstance, "Loesche DDL-Trigger '$triggerName'"))
                {
                    Invoke-DbaQuery @connParams -Query $dropSql -ErrorAction Stop
                    $msg = "Trigger '$triggerName' wurde von '$SqlInstance' entfernt."
                    Invoke-sqmLogging -Message "[$SqlInstance] $msg" -FunctionName $functionName -Level 'INFO'
                    Write-Host "  [$SqlInstance] $msg" -ForegroundColor Green
                    return [PSCustomObject]@{
                        SqlInstance = $SqlInstance
                        TriggerName = $triggerName
                        Action      = 'Removed'
                        Message     = $msg
                    }
                }

                return [PSCustomObject]@{
                    SqlInstance = $SqlInstance
                    TriggerName = $triggerName
                    Action      = 'WhatIfSkipped'
                    Message     = "WhatIf: Trigger '$triggerName' wuerde entfernt werden."
                }
            }

            # ── CREATE ───────────────────────────────────────────────────────
            if ($triggerExists)
            {
                $msg = "Trigger '$triggerName' existiert bereits auf '$SqlInstance'. Keine Aenderung. Zum Aktualisieren: -Remove dann erneut aufrufen."
                Invoke-sqmLogging -Message "[$SqlInstance] $msg" -FunctionName $functionName -Level 'INFO'
                Write-Warning $msg
                return [PSCustomObject]@{
                    SqlInstance = $SqlInstance
                    TriggerName = $triggerName
                    Action      = 'AlreadyExists'
                    Message     = $msg
                }
            }

            # Pruefe ob Zieltabelle vorhanden ist
            $tableExists = Invoke-DbaQuery @connParams `
                -Query "SELECT 1 AS Exists FROM master.sys.objects WHERE object_id = OBJECT_ID(N'master.dbo.sqm_BackupExclude') AND type = 'U'" `
                -ErrorAction Stop

            if (-not $tableExists)
            {
                $errMsg = "master.dbo.sqm_BackupExclude nicht gefunden auf '$SqlInstance'. Bitte zuerst Sync-sqmBackupExcludeTable ausfuehren."
                Invoke-sqmLogging -Message "[$SqlInstance] $errMsg" -FunctionName $functionName -Level 'ERROR'
                if ($EnableException) { throw $errMsg }
                Write-Error $errMsg
                return [PSCustomObject]@{
                    SqlInstance = $SqlInstance
                    TriggerName = $triggerName
                    Action      = 'Error'
                    Message     = $errMsg
                }
            }

            if ($PSCmdlet.ShouldProcess($SqlInstance, "Erstelle DDL-Trigger '$triggerName' (ON ALL SERVER, AFTER CREATE_DATABASE)"))
            {
                Invoke-DbaQuery @connParams -Query $createSql -ErrorAction Stop
                $msg = "DDL-Trigger '$triggerName' wurde auf '$SqlInstance' erfolgreich registriert."
                Invoke-sqmLogging -Message "[$SqlInstance] $msg" -FunctionName $functionName -Level 'INFO'
                Write-Host "  [$SqlInstance] $msg" -ForegroundColor Green
                return [PSCustomObject]@{
                    SqlInstance = $SqlInstance
                    TriggerName = $triggerName
                    Action      = 'Created'
                    Message     = $msg
                }
            }

            return [PSCustomObject]@{
                SqlInstance = $SqlInstance
                TriggerName = $triggerName
                Action      = 'WhatIfSkipped'
                Message     = "WhatIf: Trigger '$triggerName' wuerde erstellt werden."
            }
        }
        catch
        {
            $errMsg = "Fehler in $functionName auf '$SqlInstance': $($_.Exception.Message)"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level 'ERROR'
            if ($EnableException) { throw }
            Write-Error $errMsg
            return [PSCustomObject]@{
                SqlInstance = $SqlInstance
                TriggerName = $triggerName
                Action      = 'Error'
                Message     = $errMsg
            }
        }
    }

    end
    {
        Invoke-sqmLogging -Message "[$SqlInstance] $functionName abgeschlossen." -FunctionName $functionName -Level 'INFO'
    }
}
