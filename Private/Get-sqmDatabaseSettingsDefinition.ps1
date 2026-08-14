<#
.SYNOPSIS
    Liefert die gemeinsame Definition der von Export-/Import-sqmDatabaseSettings erfassten bzw.
    angewendeten Datenbank-Optionen (SSMS "Database Properties -> Options"-Seite).

.DESCRIPTION
    Single Source of Truth fuer beide Funktionen, damit Export und Import nie auseinanderlaufen:
    - Key         : Eigenschaftsname in der exportierten JSON (Export-sqmDatabaseSettings) und im
                     Ergebnis von Import-sqmDatabaseSettings.
    - SqlColumn   : Spalte in sys.databases, aus der der aktuelle Wert gelesen wird.
    - AlterOption : ALTER DATABASE ... SET <AlterOption> <Wert> Schluesselwort. $null = rein
                     informativ, wird nie per ALTER DATABASE gesetzt (z.B. Collation, State).
    - ValueKind   : Wie der Rohwert aus sys.databases in einen T-SQL SET-Wert umgewandelt wird
                     (siehe _Format-sqmDbSettingClause in Import-sqmDatabaseSettings.ps1):
                       Bit                    -> ON/OFF
                       Int                    -> Zahl direkt
                       IntSeconds             -> '<n> SECONDS' (TARGET_RECOVERY_TIME)
                       String                 -> Wert direkt uebernehmen (z.B. PAGE_VERIFY, RECOVERY,
                                                  DELAYED_DURABILITY)
                       BitAsLocalGlobal       -> 1 = LOCAL, 0 = GLOBAL (CURSOR_DEFAULT)
                       BitAsForcedSimple      -> 1 = FORCED, 0 = SIMPLE (PARAMETERIZATION)
                       BitAsReadOnlyReadWrite -> 1 = READ_ONLY, 0 = READ_WRITE
                       BitAsBrokerEnableDisable -> 1 = ENABLE_BROKER, 0 = DISABLE_BROKER
    - Exclusive   : $true = Aenderung kann aktive Verbindungen trennen (WITH ROLLBACK IMMEDIATE
                     erforderlich) und wird von Import-sqmDatabaseSettings nur mit
                     -IncludeExclusiveOptions angewendet.
#>
function Get-sqmDatabaseSettingsDefinition
{
	[CmdletBinding()]
	param ()

	return @(
		[PSCustomObject]@{ Key = 'CompatibilityLevel'; SqlColumn = 'compatibility_level'; AlterOption = 'COMPATIBILITY_LEVEL'; ValueKind = 'Int'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'RecoveryModel'; SqlColumn = 'recovery_model_desc'; AlterOption = 'RECOVERY'; ValueKind = 'String'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'PageVerifyOption'; SqlColumn = 'page_verify_option_desc'; AlterOption = 'PAGE_VERIFY'; ValueKind = 'String'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'TargetRecoveryTimeSeconds'; SqlColumn = 'target_recovery_time_in_seconds'; AlterOption = 'TARGET_RECOVERY_TIME'; ValueKind = 'IntSeconds'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'DelayedDurability'; SqlColumn = 'delayed_durability_desc'; AlterOption = 'DELAYED_DURABILITY'; ValueKind = 'String'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'AutoClose'; SqlColumn = 'is_auto_close_on'; AlterOption = 'AUTO_CLOSE'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'AutoShrink'; SqlColumn = 'is_auto_shrink_on'; AlterOption = 'AUTO_SHRINK'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'AutoCreateStatistics'; SqlColumn = 'is_auto_create_stats_on'; AlterOption = 'AUTO_CREATE_STATISTICS'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'AutoUpdateStatistics'; SqlColumn = 'is_auto_update_stats_on'; AlterOption = 'AUTO_UPDATE_STATISTICS'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'AutoUpdateStatisticsAsync'; SqlColumn = 'is_auto_update_stats_async_on'; AlterOption = 'AUTO_UPDATE_STATISTICS_ASYNC'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'AnsiNullDefault'; SqlColumn = 'is_ansi_null_default_on'; AlterOption = 'ANSI_NULL_DEFAULT'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'AnsiNulls'; SqlColumn = 'is_ansi_nulls_on'; AlterOption = 'ANSI_NULLS'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'AnsiPadding'; SqlColumn = 'is_ansi_padding_on'; AlterOption = 'ANSI_PADDING'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'AnsiWarnings'; SqlColumn = 'is_ansi_warnings_on'; AlterOption = 'ANSI_WARNINGS'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'Arithabort'; SqlColumn = 'is_arithabort_on'; AlterOption = 'ARITHABORT'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'ConcatNullYieldsNull'; SqlColumn = 'is_concat_null_yields_null_on'; AlterOption = 'CONCAT_NULL_YIELDS_NULL'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'NumericRoundabort'; SqlColumn = 'is_numeric_roundabort_on'; AlterOption = 'NUMERIC_ROUNDABORT'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'QuotedIdentifier'; SqlColumn = 'is_quoted_identifier_on'; AlterOption = 'QUOTED_IDENTIFIER'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'RecursiveTriggers'; SqlColumn = 'is_recursive_triggers_on'; AlterOption = 'RECURSIVE_TRIGGERS'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'CursorCloseOnCommit'; SqlColumn = 'is_cursor_close_on_commit_on'; AlterOption = 'CURSOR_CLOSE_ON_COMMIT'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'CursorDefaultLocal'; SqlColumn = 'is_local_cursor_default'; AlterOption = 'CURSOR_DEFAULT'; ValueKind = 'BitAsLocalGlobal'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'DateCorrelationOptimization'; SqlColumn = 'is_date_correlation_on'; AlterOption = 'DATE_CORRELATION_OPTIMIZATION'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'DbChaining'; SqlColumn = 'is_db_chaining_on'; AlterOption = 'DB_CHAINING'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'TrustworthyOn'; SqlColumn = 'is_trustworthy_on'; AlterOption = 'TRUSTWORTHY'; ValueKind = 'Bit'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'ParameterizationForced'; SqlColumn = 'is_parameterization_forced'; AlterOption = 'PARAMETERIZATION'; ValueKind = 'BitAsForcedSimple'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'HonorBrokerPriority'; SqlColumn = 'is_honor_broker_priority_on'; AlterOption = 'HONOR_BROKER_PRIORITY'; ValueKind = 'Bit'; Exclusive = $false }
		# Exclusive: koennen aktive Verbindungen trennen (WITH ROLLBACK IMMEDIATE) - nur mit
		# -IncludeExclusiveOptions angewendet.
		[PSCustomObject]@{ Key = 'ReadOnly'; SqlColumn = 'is_read_only'; AlterOption = $null; ValueKind = 'BitAsReadOnlyReadWrite'; Exclusive = $true }
		[PSCustomObject]@{ Key = 'ReadCommittedSnapshot'; SqlColumn = 'is_read_committed_snapshot_on'; AlterOption = 'READ_COMMITTED_SNAPSHOT'; ValueKind = 'Bit'; Exclusive = $true }
		[PSCustomObject]@{ Key = 'BrokerEnabled'; SqlColumn = 'is_broker_enabled'; AlterOption = $null; ValueKind = 'BitAsBrokerEnableDisable'; Exclusive = $true }
		# Rein informativ - werden erfasst, aber von Import-sqmDatabaseSettings NIE per ALTER
		# DATABASE gesetzt (Collation-Wechsel ist riskant, State/Containment/UserAccess sind kein
		# einfacher SET-Wert und gehoeren nicht auf die "Options"-Seite im engeren Sinn).
		[PSCustomObject]@{ Key = 'CollationName'; SqlColumn = 'collation_name'; AlterOption = $null; ValueKind = 'String'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'ContainmentDesc'; SqlColumn = 'containment_desc'; AlterOption = $null; ValueKind = 'String'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'StateDesc'; SqlColumn = 'state_desc'; AlterOption = $null; ValueKind = 'String'; Exclusive = $false }
		[PSCustomObject]@{ Key = 'UserAccessDesc'; SqlColumn = 'user_access_desc'; AlterOption = $null; ValueKind = 'String'; Exclusive = $false }
	)
}
