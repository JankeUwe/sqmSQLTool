<#
.SYNOPSIS
    Updates statistics in one or more databases.

.DESCRIPTION
    Executes UPDATE STATISTICS with configurable options (scan percentage, only modified statistics, etc.).
    Can be restricted to specific databases, tables, or statistics.

.PARAMETER SqlInstance
    SQL Server instance (default: current computer name).

.PARAMETER SqlCredential
    PSCredential for the connection.

.PARAMETER Database
    Database name or wildcard pattern.

.PARAMETER Table
    Table name or wildcard pattern.

.PARAMETER Statistics
    Statistic name or wildcard pattern.

.PARAMETER SamplePercent
    Percentage of rows used for the update (0 = full scan). Default: 0.

.PARAMETER OnlyModified
    Only update statistics that have changed since the last update. Default: $true.

.PARAMETER Index
    Also update statistics associated with an index. Default: $true.

.PARAMETER WhatIf
    Shows which statistics would be affected.

.PARAMETER EnableException
    Throw exceptions immediately.

.EXAMPLE
    Invoke-sqmUpdateStatistics -Database 'SalesDB' -SamplePercent 10

.NOTES
    Uses dbatools (Update-DbaDbStatistic).
#>
function Invoke-sqmUpdateStatistics {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $false)]
        [string]$SqlInstance = $env:COMPUTERNAME,
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential,
        [Parameter(Mandatory = $false)]
        [string]$Database = '*',
        [Parameter(Mandatory = $false)]
        [string]$Table = '*',
        [Parameter(Mandatory = $false)]
        [string]$Statistics = '*',
        [Parameter(Mandatory = $false)]
        [int]$SamplePercent = 0,
        [Parameter(Mandatory = $false)]
        [bool]$OnlyModified = $true,
        [Parameter(Mandatory = $false)]
        [bool]$Index = $true,
        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin {
        $functionName = $MyInvocation.MyCommand.Name
        if (-not (Get-Module -ListAvailable -Name dbatools)) {
            throw "dbatools-Modul nicht gefunden."
        }
    }

    process {
        try {
            $params = @{
                SqlInstance      = $SqlInstance
                SqlCredential    = $SqlCredential
                Database         = $Database
                Table            = $Table
                Statistic        = $Statistics
                SamplePercent    = $SamplePercent
                OnlyModified     = $OnlyModified
                Index            = $Index
                EnableException  = $EnableException
            }
            if ($PSCmdlet.ShouldProcess("UpdateStatistics on $SqlInstance", "Update")) {
                $result = Update-DbaDbStatistic @params
                $result | ForEach-Object {
                    [PSCustomObject]@{
                        Database   = $_.Database
                        Table      = $_.Table
                        Statistic  = $_.Statistic
                        Status     = 'Success'
                        Message    = "Updated"
                    }
                }
            } else {
                Write-Verbose "WhatIf: UpdateStatistics would be executed on $SqlInstance"
            }
        }
        catch {
            Invoke-sqmLogging -Message $_.Exception.Message -FunctionName $functionName -Level "ERROR"
            if ($EnableException) { throw }
        }
    }
}