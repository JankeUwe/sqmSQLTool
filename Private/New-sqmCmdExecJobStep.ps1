<#
.SYNOPSIS
    Helper: Creates a SQL Agent CmdExec job step with PowerShell wrapper.
.DESCRIPTION
    Generates a PowerShell wrapper script and creates a CmdExec job step.

    DESIGN: Inline command with NO parameter passing.
    All function parameters are hardcoded in the generated script.
    This avoids serialization issues with hashtables and complex types.

    Wrapper is generated at: C:\Program Files\WindowsPowerShell\Modules\sqmSQLTool\jobs\<FunctionName>-<JobName>.ps1
    Job step simply calls: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<wrapper-path>"

.PARAMETER SqlInstance
    SQL Server instance.
.PARAMETER JobName
    Name of the job.
.PARAMETER StepName
    Name of the job step. Default: "AutoStep_1"
.PARAMETER FunctionName
    The sqmSQLTool function to call (e.g. Compare-sqmAlwaysOnLogins).
.PARAMETER Parameters
    Hashtable of parameters to pass to the function.
.EXAMPLE
    _CreateCmdExecJobStep -SqlInstance 'SQL01' -JobName 'TestJob' `
        -FunctionName 'Compare-sqmAlwaysOnLogins' `
        -Parameters @{ AvailabilityGroupName='AG1'; OutputPath='C:\...' }
#>
function _CreateCmdExecJobStep
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SqlInstance,

        [Parameter(Mandatory = $true)]
        [string]$JobName,

        [Parameter(Mandatory = $false)]
        [string]$StepName = "AutoStep_1",

        [Parameter(Mandatory = $true)]
        [string]$FunctionName,

        [Parameter(Mandatory = $false)]
        [hashtable]$Parameters = @{}
    )

    # =========================================================================
    # 1. Ensure jobs directory exists
    # =========================================================================
    $modulePath = 'C:\Program Files\WindowsPowerShell\Modules\sqmSQLTool'
    $jobsDir = Join-Path $modulePath 'jobs'

    if (-not (Test-Path $jobsDir)) {
        New-Item -ItemType Directory -Path $jobsDir -Force | Out-Null
    }

    # =========================================================================
    # 2. Build parameter strings for inline command
    # =========================================================================
    $paramStrings = @()

    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]

        if ($value -is [bool]) {
            # Boolean: -ParamName:$true or -ParamName:$false
            $paramStrings += "-${key}:`$$value"
        }
        elseif ($value -is [int] -or $value -is [double]) {
            # Number: unquoted
            $paramStrings += "-${key} $value"
        }
        elseif ($value -is [array]) {
            # Array: @('item1','item2',...)
            $itemsQuoted = @($value | ForEach-Object { "`"$_`"" }) -join ','
            $paramStrings += "-${key} @($itemsQuoted)"
        }
        else {
            # String: quoted
            $paramStrings += "-${key} `"$value`""
        }
    }

    # Join all parameters
    $paramLine = if ($paramStrings) { " " + ($paramStrings -join " ") } else { "" }

    # =========================================================================
    # 3. Generate wrapper script with INLINE COMMAND
    # =========================================================================
    $wrapperScript = @"
# Auto-generated wrapper for SQL Agent job: $JobName
# Function: $FunctionName
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

`$ErrorActionPreference = 'Stop'
`$VerbosePreference = 'Continue'

Write-Output "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Starting $FunctionName"

try {
    Import-Module sqmSQLTool -Force -ErrorAction Stop

    # Inline command execution (no parameter passing to script)
    $FunctionName$paramLine -Verbose -ContinueOnError

    Write-Output "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Completed"
    exit 0
}
catch {
    Write-Output "ERROR: `$_"
    exit 1
}
"@

    # =========================================================================
    # 4. Write wrapper script to disk
    # =========================================================================
    $wrapperPath = Join-Path $jobsDir "$FunctionName-$JobName.ps1"
    Set-Content -Path $wrapperPath -Value $wrapperScript -Encoding UTF8 -Force

    # =========================================================================
    # 5. Create CmdExec job step
    # =========================================================================
    $psExePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $command = "$psExePath -NoProfile -ExecutionPolicy Bypass -File `"$wrapperPath`""

    $stepParams = @{
        SqlInstance = $SqlInstance
        Job         = $JobName
        StepName    = $StepName
        Subsystem   = 'CmdExec'
        Command     = $command
        ErrorAction = 'Stop'
    }

    $jobStep = New-DbaAgentJobStep @stepParams

    # =========================================================================
    # 6. Return result
    # =========================================================================
    [PSCustomObject]@{
        SqlInstance   = $SqlInstance
        JobName       = $JobName
        StepName      = $StepName
        FunctionName  = $FunctionName
        WrapperPath   = $wrapperPath
        JobStep       = $jobStep
        Status        = 'Success'
        Timestamp     = Get-Date
    }
}
