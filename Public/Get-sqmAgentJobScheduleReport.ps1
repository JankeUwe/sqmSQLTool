<#
.SYNOPSIS
    Generates a comprehensive SQL Agent Job Schedule Report.

.DESCRIPTION
    Creates an HTML report showing all SQL Agent jobs with detailed schedule information,
    execution history, and performance metrics.

    Report includes:
    - Job Name (enabled/disabled status)
    - Schedule (start time, interval, frequency)
    - Last Execution (time, status, duration)
    - Next Scheduled Execution
    - Average Job Duration
    - Last Error Message (if failed)

.PARAMETER SqlInstance
    SQL Server instance name. Default: current computer.

.PARAMETER SqlCredential
    PSCredential for the SQL Server connection.

.PARAMETER OutputPath
    Folder path for HTML report output. Default: C:\System\WinSrvLog\MSSQL
    Creates filename: AgentJobSchedule_<instance>_<timestamp>.html

.PARAMETER OutputCsv
    Also export data as CSV file.

.PARAMETER EnableException
    Throw exceptions immediately instead of logging.

.EXAMPLE
    Get-sqmAgentJobScheduleReport -SqlInstance "SQL-Server1"

.EXAMPLE
    Get-sqmAgentJobScheduleReport -SqlInstance "SQL-Server1" -OutputPath "C:\Reports" -OutputCsv

.NOTES
    Requires:
    - dbatools module
    - SQL Server 2016+ with Agent enabled
    - Access to msdb database
    - Invoke-sqmLogging function

.LINK
    Get-sqmAgentJobHistory
    Invoke-sqmSetupReport
#>
function Get-sqmAgentJobScheduleReport {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $false)]
        [string]$SqlInstance = $env:COMPUTERNAME,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath = 'C:\System\WinSrvLog\MSSQL',

        [Parameter(Mandatory = $false)]
        [switch]$OutputCsv,

        [Parameter(Mandatory = $false)]
        [switch]$EnableException
    )

    begin {
        $functionName = $MyInvocation.MyCommand.Name
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

        # Validate dbatools
        if (-not (Get-Module dbatools -ListAvailable -ErrorAction SilentlyContinue)) {
            $errMsg = "dbatools module not found. Install: Install-Module dbatools -Force"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
            if ($EnableException) { throw $errMsg } else { return }
        }

        # Create output directory if needed
        if (-not (Test-Path $OutputPath)) {
            try {
                $null = New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop
                Invoke-sqmLogging -Message "Created output directory: $OutputPath" `
                                  -FunctionName $functionName -Level "INFO"
            } catch {
                $errMsg = "Failed to create output directory '$OutputPath': $($_.Exception.Message)"
                Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
                if ($EnableException) { throw $errMsg } else { return }
            }
        }

        # Verify directory is writable
        try {
            $testFile = Join-Path $OutputPath ".sqmtest"
            $null = "test" | Out-File -FilePath $testFile -Encoding UTF8 -Force -ErrorAction Stop
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        } catch {
            $errMsg = "Output directory '$OutputPath' is not writable: $($_.Exception.Message)"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
            if ($EnableException) { throw $errMsg } else { return }
        }

        $jobData = @()
        $cleanInstance = $SqlInstance -replace '\\.*$', ''  # Remove \INSTANCE suffix for filename
    }

    process {
        try {
            Invoke-sqmLogging -Message "Starting Agent Job Report for $SqlInstance" `
                              -FunctionName $functionName -Level "INFO"

            # Get all SQL Agent jobs
            $jobs = Get-DbaAgentJob -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
                                    -ErrorAction Stop

            if (-not $jobs) {
                Invoke-sqmLogging -Message "No SQL Agent jobs found on $SqlInstance" `
                                  -FunctionName $functionName -Level "WARNING"
            }

            # Get job execution history from msdb
            $jobHistoryQuery = @"
            SELECT
                sj.name AS JobName,
                sj.enabled AS IsEnabled,
                ss.name AS ScheduleName,
                ss.freq_type AS FrequencyType,
                ss.freq_interval AS FrequencyInterval,
                ss.freq_subday_type AS SubdayType,
                ss.freq_subday_interval AS SubdayInterval,
                ss.active_start_time AS ActiveStartTime,
                MAX(jh.run_date) AS LastRunDate,
                MAX(jh.run_time) AS LastRunTime,
                MAX(CASE WHEN jh.run_status = 1 THEN 'Success' ELSE 'Failed' END) AS LastRunStatus,
                AVG(CAST(
                    (jh.run_duration / 10000 * 3600) +
                    ((jh.run_duration % 10000) / 100 * 60) +
                    (jh.run_duration % 100)
                    AS FLOAT)) AS AvgDurationSeconds,
                MAX(jh.message) AS LastErrorMessage
            FROM msdb.dbo.sysjobs sj
            LEFT JOIN msdb.dbo.sysjobschedules sjs ON sj.job_id = sjs.job_id
            LEFT JOIN msdb.dbo.sysschedules ss ON sjs.schedule_id = ss.schedule_id
            LEFT JOIN msdb.dbo.sysjobhistory jh ON sj.job_id = jh.job_id AND jh.step_id = 0
            GROUP BY sj.name, sj.enabled, ss.name, ss.freq_type, ss.freq_interval,
                     ss.freq_subday_type, ss.freq_subday_interval, ss.active_start_time
            ORDER BY sj.name
"@

            $jobHistoryData = Invoke-DbaQuery -SqlInstance $SqlInstance `
                                              -SqlCredential $SqlCredential `
                                              -Database 'msdb' `
                                              -Query $jobHistoryQuery `
                                              -ErrorAction Stop

            # Process each job
            foreach ($job in $jobs) {
                $history = $jobHistoryData | Where-Object { $_.JobName -eq $job.Name }

                # Parse schedule frequency
                $scheduleText = if ($history) {
                    _ConvertJobSchedule -FrequencyType $history.FrequencyType `
                                       -FrequencyInterval $history.FrequencyInterval `
                                       -SubdayType $history.SubdayType `
                                       -SubdayInterval $history.SubdayInterval `
                                       -StartTime $history.ActiveStartTime
                } else {
                    'No Schedule'
                }

                # Parse last execution
                $lastRunDateTime = if ($history.LastRunDate) {
                    _ConvertJobRunTime -RunDate $history.LastRunDate -RunTime $history.LastRunTime
                } else {
                    $null
                }

                # Calculate average duration
                $avgDuration = if ($history.AvgDurationSeconds -and [int]::TryParse($history.AvgDurationSeconds, [ref]$null)) {
                    $seconds = [int]$history.AvgDurationSeconds
                    "$([math]::Floor($seconds / 60))m $($seconds % 60)s"
                } else {
                    'N/A'
                }

                # Next execution estimate
                $nextExecution = if ($lastRunDateTime -and $scheduleText -ne 'No Schedule') {
                    _EstimateNextExecution -LastRun $lastRunDateTime -Schedule $scheduleText
                } else {
                    'N/A'
                }

                $jobData += [PSCustomObject]@{
                    JobName             = $job.Name
                    Enabled             = if ($job.IsEnabled) { 'Yes' } else { 'No' }
                    ScheduleName        = if ($history.ScheduleName) { $history.ScheduleName } else { 'Not Scheduled' }
                    Schedule            = $scheduleText
                    LastExecution       = if ($lastRunDateTime) { $lastRunDateTime } else { 'Never' }
                    LastStatus          = if ($history.LastRunStatus) { $history.LastRunStatus } else { 'Unknown' }
                    NextExecution       = $nextExecution
                    AvgDuration         = $avgDuration
                    LastError           = if ($history.LastErrorMessage -and $history.LastRunStatus -eq 'Failed') {
                        ($history.LastErrorMessage -replace '\[.*?\]', '' -replace '\r\n', ' ').Trim().Substring(0, [math]::Min(100, $history.LastErrorMessage.Length))
                    } else {
                        'N/A'
                    }
                    RawAvgSeconds       = if ($history.AvgDurationSeconds) { [int]$history.AvgDurationSeconds } else { 0 }
                }
            }

            # Export CSV if requested
            if ($OutputCsv -and $jobData) {
                $csvPath = Join-Path $OutputPath "AgentJobSchedule_${cleanInstance}_${timestamp}.csv"
                try {
                    $jobData | Export-Csv -Path $csvPath -NoTypeInformation -Force -ErrorAction Stop
                    Invoke-sqmLogging -Message "CSV exported to: $csvPath" `
                                      -FunctionName $functionName -Level "INFO"
                } catch {
                    $csvErr = "Failed to write CSV to '$csvPath': $($_.Exception.Message)"
                    Invoke-sqmLogging -Message $csvErr -FunctionName $functionName -Level "ERROR"
                    throw $csvErr
                }
            }

            # Generate HTML report
            $htmlPath = Join-Path $OutputPath "AgentJobSchedule_${cleanInstance}_${timestamp}.html"
            $html = _GenerateAgentJobHtml -JobData $jobData -SqlInstance $SqlInstance -Timestamp $timestamp

            try {
                $html | Out-File -FilePath $htmlPath -Encoding UTF8 -Force -ErrorAction Stop
                Invoke-sqmLogging -Message "HTML report generated: $htmlPath" `
                                  -FunctionName $functionName -Level "INFO"
            } catch {
                $fileErr = "Failed to write HTML report to '$htmlPath': $($_.Exception.Message)"
                Invoke-sqmLogging -Message $fileErr -FunctionName $functionName -Level "ERROR"
                throw $fileErr
            }

        } catch {
            $errMsg = "Error generating Agent Job Report: $($_.Exception.Message)"
            Invoke-sqmLogging -Message $errMsg -FunctionName $functionName -Level "ERROR"
            if ($EnableException) { throw } else { return }
        }
    }

    end {
        # Return all job data collected from process block
        # Note: If reports failed to write, error will have been thrown in process block
        # Only reach here if process completed successfully
        return $jobData
    }
}

# ============ Helper Functions ============

function _ConvertJobSchedule {
    param(
        [object]$FrequencyType,
        [object]$FrequencyInterval,
        [object]$SubdayType,
        [object]$SubdayInterval,
        [object]$StartTime
    )

    # Convert to int, handle NULL/empty
    [int]$FrequencyType = if ([int]::TryParse($FrequencyType, [ref]$null)) { [int]$FrequencyType } else { 0 }
    [int]$FrequencyInterval = if ([int]::TryParse($FrequencyInterval, [ref]$null)) { [int]$FrequencyInterval } else { 0 }
    [int]$SubdayType = if ([int]::TryParse($SubdayType, [ref]$null)) { [int]$SubdayType } else { 0 }
    [int]$SubdayInterval = if ([int]::TryParse($SubdayInterval, [ref]$null)) { [int]$SubdayInterval } else { 0 }
    [int]$StartTime = if ([int]::TryParse($StartTime, [ref]$null)) { [int]$StartTime } else { 0 }

    if (-not $FrequencyType) { return 'No Schedule' }

    # Frequency Type: 1=Once, 4=Daily, 8=Weekly, 16=Monthly, 32=Monthly Relative, 64=When Agent starts, 128=When CPU idle
    $freqDesc = switch ($FrequencyType) {
        1  { 'One Time' }
        4  { "Daily (every $FrequencyInterval day(s))" }
        8  { 'Weekly' }
        16 { "Monthly (day $FrequencyInterval)" }
        32 { 'Monthly (relative)' }
        64 { 'When SQL Agent starts' }
        128 { 'When CPU is idle' }
        default { "Frequency Type: $FrequencyType" }
    }

    # Add subday interval if present
    # freq_subday_type: 1=AtSpecifiedTime, 2=Seconds, 4=Minutes, 8=Hours, 16=Days
    if ($SubdayType -and $SubdayInterval) {
        $subdayDesc = switch ($SubdayType) {
            1 { '' }  # At specified time only - no subday interval
            2 { "every $SubdayInterval second(s)" }
            4 { "every $SubdayInterval minute(s)" }
            8 { "every $SubdayInterval hour(s)" }
            16 { "every $SubdayInterval day(s)" }
            default { '' }
        }
        if ($subdayDesc) {
            $freqDesc += " $subdayDesc"
        }
    }

    # Add start time (format: HHMMSS)
    if ($StartTime -gt 0) {
        $hours = [int][math]::Floor($StartTime / 10000)
        $minutes = [int][math]::Floor(($StartTime % 10000) / 100)
        $seconds = [int]($StartTime % 100)

        # Format as HH:MM or HH:MM:SS if seconds present
        if ($seconds -gt 0) {
            $timeStr = "{0:D2}:{1:D2}:{2:D2}" -f $hours, $minutes, $seconds
        } else {
            $timeStr = "{0:D2}:{1:D2}" -f $hours, $minutes
        }
        $freqDesc += " @ $timeStr"
    }

    return $freqDesc
}

function _ConvertJobRunTime {
    param(
        [object]$RunDate,
        [object]$RunTime
    )

    # Safe conversion from SQL NULL/empty
    [int]$RunDate = if ([int]::TryParse($RunDate, [ref]$null)) { [int]$RunDate } else { 0 }
    [int]$RunTime = if ([int]::TryParse($RunTime, [ref]$null)) { [int]$RunTime } else { 0 }

    try {
        $dateStr = $RunDate.ToString('00000000')
        $timeStr = $RunTime.ToString('000000')

        $year = [int]$dateStr.Substring(0, 4)
        $month = [int]$dateStr.Substring(4, 2)
        $day = [int]$dateStr.Substring(6, 2)

        $hour = [int]$timeStr.Substring(0, 2)
        $minute = [int]$timeStr.Substring(2, 2)
        $second = [int]$timeStr.Substring(4, 2)

        $dt = New-Object DateTime($year, $month, $day, $hour, $minute, $second)
        return $dt.ToString('yyyy-MM-dd HH:mm:ss')
    } catch {
        return 'Invalid DateTime'
    }
}

function _EstimateNextExecution {
    param(
        [datetime]$LastRun,
        [string]$Schedule
    )

    # Simple heuristics based on schedule text
    if ($Schedule -match 'Daily.*every (\d+)') {
        $days = [int]$matches[1]
        return ($LastRun.AddDays($days)).ToString('yyyy-MM-dd HH:mm')
    } elseif ($Schedule -match 'every (\d+) hour') {
        $hours = [int]$matches[1]
        return ($LastRun.AddHours($hours)).ToString('yyyy-MM-dd HH:mm')
    } elseif ($Schedule -match 'every (\d+) minute') {
        $minutes = [int]$matches[1]
        return ($LastRun.AddMinutes($minutes)).ToString('yyyy-MM-dd HH:mm')
    } else {
        return 'N/A'
    }
}

function _GenerateAgentJobHtml {
    param(
        [PSCustomObject[]]$JobData,
        [string]$SqlInstance,
        [string]$Timestamp
    )

    $reportDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $successCount = ($JobData | Where-Object { $_.LastStatus -eq 'Success' }).Count
    $failureCount = ($JobData | Where-Object { $_.LastStatus -eq 'Failed' }).Count
    $disabledCount = ($JobData | Where-Object { $_.Enabled -eq 'No' }).Count

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SQL Agent Job Schedule Report</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Arial, sans-serif;
            background: #0f172a;
            color: #e2e8f0;
            padding: 20px;
        }
        .container { max-width: 1600px; margin: 0 auto; }

        .header {
            background: linear-gradient(160deg, #1e3a8a 0%, #2e5090 100%);
            padding: 30px;
            border-radius: 12px;
            margin-bottom: 30px;
            border-left: 4px solid #3b82f6;
        }

        .header h1 {
            color: #60a5fa;
            font-size: 2em;
            margin-bottom: 10px;
        }

        .header p {
            color: #94a3b8;
            font-size: 0.95em;
        }

        .stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 15px;
            margin-bottom: 30px;
        }

        .stat-card {
            background: #0b1e3d;
            border: 1px solid #3b82f6;
            padding: 20px;
            border-radius: 8px;
            text-align: center;
        }

        .stat-value {
            font-size: 2.2em;
            font-weight: bold;
            color: #34d399;
            margin-bottom: 5px;
        }

        .stat-label {
            color: #94a3b8;
            font-size: 0.9em;
        }

        .controls {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
        }

        .controls input {
            background: #0b1e3d;
            border: 1px solid #3b82f6;
            color: #e2e8f0;
            padding: 10px;
            border-radius: 6px;
            flex: 1;
            max-width: 300px;
        }

        .controls button {
            background: #1e3a8a;
            border: 1px solid #3b82f6;
            color: #60a5fa;
            padding: 10px 20px;
            border-radius: 6px;
            cursor: pointer;
            font-weight: bold;
        }

        .controls button:hover { background: #2e5090; }

        table {
            width: 100%;
            border-collapse: collapse;
            background: #0b1e3d;
            border-radius: 8px;
            overflow: hidden;
            margin-bottom: 30px;
        }

        th {
            background: #1e3a8a;
            color: #60a5fa;
            padding: 15px;
            text-align: left;
            font-weight: 600;
            border-bottom: 2px solid #3b82f6;
        }

        td {
            padding: 12px 15px;
            border-bottom: 1px solid #2d5a8c;
        }

        tr:hover { background: #1a2f4d; }

        .job-name {
            color: #60a5fa;
            font-weight: 600;
            font-family: monospace;
        }

        .status-success {
            color: #34d399;
            font-weight: bold;
        }

        .status-failed {
            color: #ef4444;
            font-weight: bold;
        }

        .status-unknown {
            color: #94a3b8;
        }

        .enabled-yes {
            color: #34d399;
        }

        .enabled-no {
            color: #f59e0b;
        }

        .footer {
            color: #94a3b8;
            font-size: 0.85em;
            text-align: center;
            margin-top: 50px;
            padding-top: 20px;
            border-top: 1px solid #3b82f6;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>📊 SQL Agent Job Schedule Report</h1>
            <p>Server: <strong>$SqlInstance</strong> | Generated: $reportDate</p>
        </div>

        <div class="stats">
            <div class="stat-card">
                <div class="stat-value">$($JobData.Count)</div>
                <div class="stat-label">Total Jobs</div>
            </div>
            <div class="stat-card">
                <div class="stat-value" style="color: #34d399;">$successCount</div>
                <div class="stat-label">Last Success</div>
            </div>
            <div class="stat-card">
                <div class="stat-value" style="color: #ef4444;">$failureCount</div>
                <div class="stat-label">Last Failed</div>
            </div>
            <div class="stat-card">
                <div class="stat-value" style="color: #f59e0b;">$disabledCount</div>
                <div class="stat-label">Disabled</div>
            </div>
        </div>

        <div class="controls">
            <input type="text" id="searchBox" placeholder="Search job name..." onkeyup="filterTable()">
            <button onclick="sortTable('JobName')">Sort by Name</button>
            <button onclick="sortTable('AvgDuration')">Sort by Duration</button>
        </div>

        <table id="jobTable">
            <thead>
                <tr>
                    <th style="width: 20%;">Job Name</th>
                    <th style="width: 8%;">Status</th>
                    <th style="width: 8%;">Enabled</th>
                    <th style="width: 20%;">Schedule</th>
                    <th style="width: 14%;">Last Execution</th>
                    <th style="width: 12%;">Next Execution</th>
                    <th style="width: 10%;">Avg Duration</th>
                    <th style="width: 18%;">Last Error</th>
                </tr>
            </thead>
            <tbody>
"@

    # Add table rows
    foreach ($job in $JobData) {
        $statusClass = switch ($job.LastStatus) {
            'Success' { 'status-success' }
            'Failed' { 'status-failed' }
            default { 'status-unknown' }
        }

        $enabledClass = switch ($job.Enabled) {
            'Yes' { 'enabled-yes' }
            'No' { 'enabled-no' }
        }

        $html += @"
                <tr>
                    <td class="job-name">$($job.JobName)</td>
                    <td class="$statusClass">$($job.LastStatus)</td>
                    <td class="$enabledClass">$($job.Enabled)</td>
                    <td style="font-size: 0.9em; color: #94a3b8;">$($job.Schedule)</td>
                    <td style="color: #5dade2;">$($job.LastExecution)</td>
                    <td style="color: #5dade2;">$($job.NextExecution)</td>
                    <td style="font-weight: 600;">$($job.AvgDuration)</td>
                    <td style="color: #f59e0b; font-size: 0.85em;">$($job.LastError)</td>
                </tr>
"@
    }

    $html += @"
            </tbody>
        </table>

        <div class="footer">
            <p>Generated by sqmSQLTool | Get-sqmAgentJobScheduleReport</p>
            <p>Report ID: $Timestamp</p>
        </div>
    </div>

    <script>
        function filterTable() {
            const input = document.getElementById('searchBox');
            const filter = input.value.toLowerCase();
            const table = document.getElementById('jobTable');
            const rows = table.getElementsByTagName('tr');

            for (let i = 1; i < rows.length; i++) {
                const jobName = rows[i].cells[0].textContent.toLowerCase();
                rows[i].style.display = jobName.includes(filter) ? '' : 'none';
            }
        }

        function sortTable(column) {
            const table = document.getElementById('jobTable');
            const tbody = table.querySelector('tbody');
            const rows = Array.from(tbody.querySelectorAll('tr'));

            const columnIndex = {
                'JobName': 0,
                'LastStatus': 1,
                'AvgDuration': 6
            }[column] || 0;

            rows.sort((a, b) => {
                const aText = a.cells[columnIndex].textContent.trim();
                const bText = b.cells[columnIndex].textContent.trim();
                return aText.localeCompare(bText);
            });

            rows.forEach(row => tbody.appendChild(row));
        }
    </script>
</body>
</html>
"@

    return $html
}
