$ErrorActionPreference = 'Stop'
$pub  = 'C:\CCM\SQL-Tools\sqmSQLTool\Public'
$file = 'C:\CCM\SQL-Tools\sqmSQLTool\Docs\sqmSQLTool-reference.html'

$globe = [char]::ConvertFromUtf32(0x1F310)
$cats = [ordered]@{}
$cats['alwayson']            = @{ Title="$([char]::ConvertFromUtf32(0x1F504)) AlwaysOn";              Badge='alwayson';      Text='AlwaysOn' }
$cats['distributed-ag']      = @{ Title="$globe Distributed AG";                                       Badge='distributed';   Text='Distributed' }
$cats['service-broker']      = @{ Title="$([char]::ConvertFromUtf32(0x1F4E8)) Service Broker";         Badge='monitoring';    Text='ServiceBroker' }
$cats['backup-&-restore']    = @{ Title="$([char]::ConvertFromUtf32(0x1F4BE)) Backup & Restore";       Badge='backup';        Text='Backup' }
$cats['sicherheit']          = @{ Title="$([char]::ConvertFromUtf32(0x1F512)) Security";               Badge='sicherheit';    Text='Security' }
$cats['diagnose-&-health']   = @{ Title="$([char]::ConvertFromUtf32(0x1FA7A)) Diagnostics & Health";   Badge='diagnose';      Text='Diagnostics' }
$cats['performance']         = @{ Title="$([char]::ConvertFromUtf32(0x26A1)) Performance";             Badge='performance';   Text='Performance' }
$cats['wartung']             = @{ Title="$([char]::ConvertFromUtf32(0x1F527)) Maintenance";            Badge='wartung';       Text='Maintenance' }
$cats['sql-konfiguration']   = @{ Title="$([char]::ConvertFromUtf32(0x2699))$([char]::ConvertFromUtf32(0xFE0F)) SQL Configuration"; Badge='konfiguration'; Text='SQL Config' }
$cats['sqmtool-config']      = @{ Title="$([char]::ConvertFromUtf32(0x1F527)) sqmTool Config";         Badge='restore';       Text='sqmTool' }
$cats['inventar-&-suche']    = @{ Title="$([char]::ConvertFromUtf32(0x1F4CB)) Inventory & Search";     Badge='inventar';      Text='Inventory' }
$cats['cluster-&-dienste']   = @{ Title="$([char]::ConvertFromUtf32(0x1F5A5))$([char]::ConvertFromUtf32(0xFE0F)) Cluster & Services"; Badge='monitoring'; Text='Cluster' }
$cats['tls-&-zertifikate']   = @{ Title="$([char]::ConvertFromUtf32(0x1F510)) TLS & Certificates";     Badge='konfiguration'; Text='TLS' }
$cats['tsm-/-ibm-spectrum']  = @{ Title="$([char]::ConvertFromUtf32(0x1F4FC)) TSM / IBM Spectrum";     Badge='tsm';           Text='TSM' }
$cats['driver']              = @{ Title="$([char]::ConvertFromUtf32(0x1F50C)) Driver Install/Uninstall"; Badge='kapazitaet';  Text='Driver' }
$cats['deployment']          = @{ Title="$([char]::ConvertFromUtf32(0x1F680)) Deployment";             Badge='deployment';    Text='Deployment' }
$cats['sonstige']            = @{ Title="$([char]::ConvertFromUtf32(0x1F539)) Other";                  Badge='sonstige';      Text='Other' }

$members = [ordered]@{}
$members['alwayson'] = 'Add-sqmDatabaseToAG','Compare-sqmAlwaysOnLogins','Compare-sqmAlwaysOnRoles','Complete-sqmListenerMigration','Export-sqmAlwaysOnConfiguration','Get-sqmAlwaysOnFailoverHistory','Get-sqmAlwaysOnHealthReport','Invoke-sqmAlwaysOnSetup','Invoke-sqmFailover','Invoke-sqmSqlAlwaysOnAutoseeding','Move-sqmAlwaysOnListener','New-sqmAlwaysOnRepairJob','New-sqmAutoLoginSyncJob','New-sqmAvailabilityGroup','Remove-sqmDatabaseFromAG','Repair-sqmAlwaysOnDatabases','Sync-sqmAgNode','Sync-sqmLoginsToAlwaysOn'
$members['distributed-ag'] = 'Add-sqmDatabaseToDistributedAg','Get-sqmDistributedAgHealth','Invoke-sqmDistributedFailover','New-sqmDistributedAvailabilityGroup','Test-sqmDistributedAgReadiness'
$members['service-broker'] = 'Enable-sqmServiceBroker','Get-sqmServiceBrokerHealth','Invoke-sqmServiceBrokerAlwaysOn'
$members['backup-&-restore'] = 'Get-sqmServersFromOU','Invoke-sqmLogShrink','Invoke-sqmRestoreDatabase','Invoke-sqmUserDatabaseBackup','New-sqmBackupMaintenanceJob','New-sqmOlaSysDbBackupJob','New-sqmOlaUsrDbBackupJob','Register-sqmBackupExcludeTrigger','Set-sqmBackupExcludePermission','Show-sqmBackupExcludeForm','Sync-sqmBackupExcludeTable','Test-sqmBackupIntegrity'
$members['sicherheit'] = 'Enable-sqmMonitoringAccess','Find-sqmADUser','Get-sqmADAccountStatus','Get-sqmADGroupMembers','Get-sqmADGroupMembersRecursive','Get-sqmADMemberGroups','Get-sqmLoginSettings','Get-sqmSysadminAccounts','Grant-sqmTemporarySysadmin','Invoke-sqmLoginAudit','Invoke-sqmSaObfuscation','Invoke-sqmTempSysadminAction','Remove-sqmAdOrphanLogin','Set-sqmDatabaseOwner'
$members['diagnose-&-health'] = 'Copy-sqmNTFSPermissions','Get-sqmAgentJobScheduleReport','Get-sqmConnectionStats','Get-sqmDatabaseHealth','Get-sqmDiskInfoByDriveLetter','Get-sqmDiskPartitionMap','Get-sqmDiskSpaceReport','Get-sqmOperationStatus','Get-sqmOrphanedFiles','Get-sqmSpnReport','Get-sqmSQLInstanceCheck','Get-sqmTempDbRecommendation','Invoke-sqmPatchAnalysis','Invoke-sqmSetupReport','New-sqmAgentProxy','New-sqmSetupReport','Test-sqmCostThreshold','Test-sqmTempDbFileCount'
$members['performance'] = 'Get-sqmAutoGrowthReport','Get-sqmBlockingReport','Get-sqmDeadlockReport','Get-sqmIndexFragmentation','Get-sqmLongRunningQueries','Get-sqmMissingIndexes','Get-sqmPerfCounters','Get-sqmServerUtilization','Get-sqmWaitStatistics','Invoke-sqmExtendedEvents','Invoke-sqmPerfBaseline','Invoke-sqmQueryStore','Invoke-sqmUpdateStatistics'
$members['wartung'] = 'Invoke-sqmFormatDrive64k','Invoke-sqmNtfsSetup','Test-sqmOlaInstallation','Test-sqmSQLFirewall'
$members['sql-konfiguration'] = 'Compare-sqmServerConfiguration','Get-sqmServerSetting','Invoke-sqmCollationChange','Invoke-sqmSetDatabaseRecoveryMode','Invoke-sqmSsisConfiguration','Set-sqmMaxDop','Set-sqmMaxMemory','Set-sqmSsrsConfiguration','Set-sqmTcpPort','Test-sqmMaxDop','Test-sqmMaxMemory'
$members['sqmtool-config'] = 'Get-sqmConfig','Set-sqmConfig'
$members['inventar-&-suche'] = 'Export-sqmDatabaseDocumentation','Export-sqmServerConfiguration','Find-sqmDatabaseObject','Get-sqmLinkedServerUsage','Invoke-sqmConfigRollback','Invoke-sqmInstanceInventory'
$members['cluster-&-dienste'] = 'Get-sqmClusterInfo','Set-sqmSsasDeploymentMode','Test-sqmSsasDirectoryPermissions','Test-sqmSSISPackageCompatibility'
$members['tls-&-zertifikate'] = 'Get-sqmCertificateReport','Get-sqmTlsStatus','Install-sqmCertificate','Install-sqmCertificateToStore','New-sqmCertificateRequest','New-sqmSqlCertificate','Set-sqmSqlTlsCertificate','Set-sqmSsrsHttpsCertificate'
$members['tsm-/-ibm-spectrum'] = 'Get-sqmTsmConfiguration','Invoke-sqmTsmConfiguration','Test-sqmTsmConnection'
$members['driver'] = 'Install-sqmDb2Driver','Install-sqmJdbcDriver','Install-sqmOdbcDriver','Test-sqmDriverInstalled','Uninstall-sqmDb2Driver','Uninstall-sqmJdbcDriver','Uninstall-sqmOdbcDriver'
$members['deployment'] = 'Invoke-sqmDeployScripts','Invoke-sqmSignModule'
$members['sonstige'] = 'Copy-sqmLogins','Copy-sqmToCentralPath','Get-sqmAgentJobHistory','Get-sqmDiskBlockSize','Get-sqmHpuAllowGroup','Get-sqmServerHardwareReport','Install-sqmAdModule','Install-sqmOlaMaintenanceSolution','Install-sqmSsrsReportServer','Invoke-sqmMonitoringKey','New-sqmOlaMaintenanceJobs','New-sqmRandomSaPassword','Set-sqmSqlPolicyState','Show-sqmToolGui','Test-sqmSqlInstanceInstalled','Write-sqmSetupEvent'

$deTrans = @{
  'Compare-sqmAlwaysOnLogins'    = 'Compares the logins of all replicas in an AlwaysOn availability group.'
  'Get-sqmAlwaysOnFailoverHistory'= 'Retrieves AlwaysOn failover events from the Windows Event Log.'
  'Enable-sqmMonitoringAccess'   = 'Sets up a monitoring account on all SQL Server instances of a computer.'
  'Find-sqmADUser'               = 'Searches Active Directory for user accounts by a wildcard name pattern.'
  'Set-sqmSsasDeploymentMode'    = 'Corrects the DeploymentMode of an SSAS instance (Multidimensional <-> Tabular) after installation.'
  'Get-sqmLoginSettings'         = 'Lists all logins with their default database and language setting.'
  'New-sqmAgentProxy'            = 'Creates a SQL Server credential and a SQL Agent proxy and links them together.'
  'Set-sqmTcpPort'               = 'Configures the TCP port of a SQL Server instance via the registry.'
  'Get-sqmServerHardwareReport'  = 'Creates an HTML hardware configuration report for one or more servers.'
  'Install-sqmDb2Driver'         = 'Installs the IBM DB2 ODBC/CLI driver.'
  'Install-sqmJdbcDriver'        = 'Installs the Microsoft JDBC Driver for SQL Server.'
  'Install-sqmOdbcDriver'        = 'Installs the Microsoft ODBC Driver for SQL Server.'
  'New-sqmRandomSaPassword'      = 'Generates a random, policy-compliant SA password.'
  'Test-sqmDriverInstalled'      = 'Checks whether a JDBC, ODBC or DB2 driver is installed on the system.'
  'Test-sqmMaxDop'               = 'Checks whether MAXDOP (Max Degree of Parallelism) is configured correctly.'
  'Test-sqmMaxMemory'            = 'Checks whether SQL Server Max Server Memory is configured correctly.'
  'Test-sqmSqlInstanceInstalled' = 'Checks whether a SQL Server instance is installed on the local system.'
  'Uninstall-sqmDb2Driver'       = 'Uninstalls the IBM DB2 ODBC/CLI driver.'
  'Uninstall-sqmJdbcDriver'      = 'Uninstalls the Microsoft JDBC Driver for SQL Server.'
  'Uninstall-sqmOdbcDriver'      = 'Uninstalls the Microsoft ODBC Driver for SQL Server.'
}

$real = Get-ChildItem $pub -Filter *.ps1 | ForEach-Object {
  $n=$_.Name -replace '\.ps1$',''; $c=Get-Content $_.FullName -Raw
  if($c -match '(?m)^\s*function\s+([A-Za-z0-9_-]+)' -and $matches[1] -eq $n){$n}
}
$all = $members.Values | ForEach-Object { $_ }
$dupe = $all | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name
if($dupe){ throw "Doppelte Zuordnung: $($dupe -join ', ')" }
if($real | Where-Object { $_ -notin $all }){ throw "Nicht zugeordnet" }
if($all | Where-Object { $_ -notin $real }){ throw "Nicht real" }
Write-Host "OK: $($all.Count) Funktionen."

function Enc([string]$t){ $t -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'",'&#39;' }
function Fid([string]$n){ 'f-' + ($n.ToLower() -replace '[^a-z0-9]','') }
$tri = [char]0x25B6

function Get-Meta([string]$name){
  $raw = Get-Content (Join-Path $pub "$name.ps1") -Raw
  $help=''; if($raw -match '(?s)<#(.*?)#>'){ $help=$matches[1] }
  $syn=''
  if($help -match '(?s)\.SYNOPSIS\s*(.*?)\r?\n\s*\.[A-Z]'){ $syn=($matches[1] -replace '\s+',' ').Trim() }
  $ex=@()
  foreach($m in [regex]::Matches($help,'(?s)\.EXAMPLE\b[ \t]*\r?\n(.*?)(?=\r?\n\s*\.[A-Z][A-Z]|\Z)')){
    $b = $m.Groups[1].Value.TrimEnd()
    $b = ($b -replace '^(?:\s*\r?\n)+','')
    if($b.Trim()){ $ex += ,$b }
  }
  [pscustomobject]@{ Syn=$syn; Examples=$ex }
}

$htmlOrig = Get-Content $file -Raw -Encoding UTF8
$ovMap = @{}
foreach($m in [regex]::Matches($htmlOrig,'<td class="psdb-st-ov-fn">([^<]+)</td><td>(.*?)</td>')){
  $ovMap[$m.Groups[1].Value] = $m.Groups[2].Value
}
function Desc([string]$fn,$meta){
  if($deTrans.ContainsKey($fn)){ return (Enc $deTrans[$fn]) }
  if($ovMap.ContainsKey($fn) -and $ovMap[$fn].Trim()){ return $ovMap[$fn] }
  return (Enc $meta.Syn)
}

$sbCard = New-Object System.Text.StringBuilder
$sbNav  = New-Object System.Text.StringBuilder
$ovRows = New-Object System.Collections.Generic.List[object]

foreach($cid in $members.Keys){
  $cat = $cats[$cid]
  $fns = $members[$cid] | Sort-Object
  [void]$sbNav.AppendLine("`t<div class=`"psdb-st-nav-group`" id=`"nav-$cid`">")
  [void]$sbNav.AppendLine("`t<div class=`"psdb-st-nav-cat`" onclick=`"psstToggleCat('nav-$cid-list')`">")
  [void]$sbNav.AppendLine("`t<span>$($cat.Title)</span><span class=`"psdb-st-nav-count`">$($fns.Count)</span>")
  [void]$sbNav.AppendLine("`t</div>")
  $lis = ($fns | ForEach-Object { "<li><span class=`"psdb-st-nav-func`" onclick=`"psstJump('$(Fid $_)')`">$_</span></li>" }) -join "`n"
  [void]$sbNav.AppendLine("`t<ul class=`"psdb-st-nav-funcs`" id=`"nav-$cid-list`">$lis</ul>")
  [void]$sbNav.AppendLine("`t</div>")
  [void]$sbNav.AppendLine("")

  [void]$sbCard.AppendLine("`t<section class=`"psdb-st-section`" id=`"cat-$cid`">")
  [void]$sbCard.AppendLine("`t<h2 class=`"psdb-st-section-title`">$($cat.Title)</h2>")
  [void]$sbCard.AppendLine("")
  foreach($fn in $fns){
    $meta = Get-Meta $fn
    $desc = Desc $fn $meta
    [void]$sbCard.AppendLine("`t<div class=`"psdb-st-func-card`" id=`"$(Fid $fn)`">")
    [void]$sbCard.AppendLine("`t<div class=`"psdb-st-func-header`">")
    [void]$sbCard.AppendLine("`t<span class=`"psdb-st-func-name`">$fn</span>")
    [void]$sbCard.AppendLine("`t<span class=`"psdb-st-badge psdb-st-badge-$($cat.Badge)`">$($cat.Text)</span>")
    [void]$sbCard.AppendLine("`t</div>")
    [void]$sbCard.AppendLine("`t<div class=`"psdb-st-func-desc`">$desc</div>")
    if($meta.Examples.Count -gt 0){
      [void]$sbCard.AppendLine("`t<div class=`"psdb-st-examples-toggle`" onclick=`"psstToggleEx(this)`">$tri Show $($meta.Examples.Count) examples</div>")
      [void]$sbCard.AppendLine("`t<div class=`"psdb-st-examples`">")
      foreach($e in $meta.Examples){
        $label = ($e -split "`r?`n")[0].Trim()
        [void]$sbCard.AppendLine("`t<div class=`"psdb-st-example`">")
        [void]$sbCard.AppendLine("`t<div class=`"psdb-st-example-label`">$(Enc $label)</div>")
        [void]$sbCard.AppendLine("`t<div class=`"psdb-st-pre-wrap`"><pre class=`"psdb-st-code`">$(Enc $e)</pre><button class=`"psdb-st-copy-btn`" onclick=`"psstCopy(this)`">copy</button></div>")
        [void]$sbCard.AppendLine("`t</div>")
      }
      [void]$sbCard.AppendLine("`t</div>")
    }
    [void]$sbCard.AppendLine("`t</div>")
    [void]$sbCard.AppendLine("")
    $ovRows.Add([pscustomobject]@{ Name=$fn; Desc=$desc })
  }
  [void]$sbCard.AppendLine("`t</section>")
  [void]$sbCard.AppendLine("")
}

$ovHtml = (($ovRows | Sort-Object Name | ForEach-Object {
  "`t<tr><td class=`"psdb-st-ov-fn`">$($_.Name)</td><td>$($_.Desc)</td></tr>"
}) -join "`n")

$h = $htmlOrig
$total = $all.Count

$navStart = $h.IndexOf('<div class="psdb-st-nav-group" id="nav-alwayson">')
$navEnd   = $h.IndexOf('</div><!-- /sidebar -->')
$newNav = ($sbNav.ToString().TrimEnd("`r","`n")) + "`r`n`r`n`t"
$h = $h.Substring(0,$navStart) + $newNav + $h.Substring($navEnd)

$cardStart = $h.IndexOf('<section class="psdb-st-section" id="cat-alwayson">')
$closeMk   = "`r`n`t</div>`r`n`t</div>`r`n`t</div>`r`n`r`n`t<div id=`"tab-quick`""
$cardEnd   = $h.IndexOf($closeMk)
if($cardEnd -lt 0){ $closeMk = "</div>`n`t</div>`n`t</div>`n`n`t<div id=`"tab-quick`""; $cardEnd = $h.IndexOf($closeMk) }
$lastSecClose = $h.LastIndexOf('</section>',$cardEnd)
$afterTail = $h.Substring($lastSecClose + '</section>'.Length, $cardEnd - ($lastSecClose + '</section>'.Length))
$newCards = ($sbCard.ToString().TrimEnd("`r","`n")) + $afterTail
$h = $h.Substring(0,$cardStart) + $newCards + $h.Substring($cardEnd)

$ovIdx     = $h.IndexOf('id="psdb-st-ov-table"')
$tbodyOpen = $h.IndexOf('<tbody>',$ovIdx) + '<tbody>'.Length
$tbodyEnd  = $h.IndexOf('</tbody>',$tbodyOpen)
$h = $h.Substring(0,$tbodyOpen) + "`r`n" + $ovHtml + "`r`n`t" + $h.Substring($tbodyEnd)

$h = $h.Replace('>122 Funktionen<', ">$total Funktionen<")
$h = $h.Replace('Alle Funktionen (122)', "Alle Funktionen ($total)")
$h = $h.Replace('mit 122 Funktionen', "mit $total Funktionen")

if($h -notmatch '\.psdb-st-badge-distributed \{'){
  $anchor = '.psdb-st-badge-deployment { background: rgba(46,134,193,0.2); color: #5dade2; }'
  $h = $h.Replace($anchor, $anchor + "`r`n`t.psdb-st-badge-distributed { background: rgba(8,145,178,0.2); color: #67e8f9; }")
}

$h = $h.Replace('Referenz</div>', 'Reference</div>')
$h = $h.Replace('Konfiguration</div>', 'Configuration</div>')
$h = $h.Replace([char]0x00DC + 'bersicht</div>', 'Overview</div>')
$h = $h.Replace('Konfiguration</h2>', 'Configuration</h2>')
$h = $h.Replace(">$total Funktionen<", ">$total Functions<")
$h = $h.Replace('Alle Funktionen (', 'All Functions (')
$h = $h.Replace('Funktion suchen...', 'Search function...')
$h = $h.Replace('<th>Funktion</th>', '<th>Function</th>')
$h = $h.Replace('<th>Beschreibung</th>', '<th>Description</th>')
$h = $h.Replace('<th>Beispiel</th>', '<th>Example</th>')
$h = $h.Replace('sqmSQLTool ist ein modulares PowerShell-Toolset f' + [char]0x00FC + 'r die SQL Server Administration mit ' + $total + ' Funktionen', 'sqmSQLTool is a modular PowerShell toolset for SQL Server administration with ' + $total + ' functions')
$h = $h.Replace('Modul importieren', 'Import module')
$h = $h.Replace('Konfiguration setzen', 'Set configuration')
$h = $h.Replace('Instanz pr' + [char]0x00FC + 'fen', 'Check instance')
$h = $h.Replace('Alle Einstellungen werden mit ', 'All settings are set with ')
$h = $h.Replace(' gesetzt und mit ', ' and retrieved with ')
$h = $h.Replace(' abgerufen.</div>', '.</div>')
$h = $h.Replace('Pfad f' + [char]0x00FC + 'r Log-Dateien', 'Path for log files')
$h = $h.Replace('Pfad f' + [char]0x00FC + 'r Report-Ausgaben', 'Path for report output')
$h = $h.Replace('Zentraler UNC-Pfad', 'Central UNC path')
$h = $h.Replace('Automatisches Update beim Import aktivieren', 'Enable automatic update on import')
$h = $h.Replace('Sprache der Ausgaben', 'Output language')
$h = $h.Replace('</code> oder <code>', '</code> or <code>')
$h = $h.Replace('Standard-Policy-Name', 'Default policy name')
$h = $h.Replace('Pr' + [char]0x00FC + 'fprofil', 'Check profile')
$h = $h.Replace('Mindestwert f' + [char]0x00FC + 'r Cost', 'Minimum cost')
$h = $h.Replace('TempDB-Dateien f' + [char]0x00FC + 'r', 'TempDB files for')
$h = $h.Replace('Block-Gr' + [char]0x00F6 + [char]0x00DF + 'e', 'block size')
$h = $h.Replace('Name des Ola Full-Backup Jobs', 'Name of the Ola full backup job')
$h = $h.Replace('Name des Ola Diff-Backup Jobs', 'Name of the Ola diff backup job')
$h = $h.Replace('Name des Ola Log-Backup Jobs', 'Name of the Ola log backup job')
$h = $h.Replace('Beispiel: Grundkonfiguration', 'Example: Basic configuration')
$h = $h.Replace('Voraussetzung: dbatools installieren', 'Prerequisite: install dbatools')
$h = $h.Replace('Falls dbatools noch nicht vorhanden', 'If dbatools is not present yet')
$h = $h.Replace('Mit Internetzugang (PSGallery):', 'With internet access (PSGallery):')
$h = $h.Replace('systemweit (als Admin)', 'system-wide (as admin)')
$h = $h.Replace('nur f' + [char]0x00FC + 'r aktuellen', 'current user only')
$h = $h.Replace('Ohne Internetzugang', 'Without internet access')
$h = $h.Replace('dbatools als ZIP', 'Provide dbatools as ZIP')
$h = $h.Replace('UNC-Share bereitstellen', 'UNC share and')
$h = $h.Replace('manuell entpacken nach:', 'extract manually to:')
$h = $h.Replace('sqmSQLTool herunterladen', 'Download sqmSQLTool')
$h = $h.Replace('Von GitHub als ZIP:', 'From GitHub as ZIP:')
$h = $h.Replace('Download ZIP', 'Download ZIP')
$h = $h.Replace('entpacken', 'extract')
$h = $h.Replace('Installation mit Install.cmd (empfohlen)', 'Installation with Install.cmd (recommended)')
$h = $h.Replace('erkennt automatisch ob Admin-Rechte', 'automatically detects whether admin rights')
$h = $h.Replace('behandelt Execution Policy', 'handles the execution policy')
$h = $h.Replace('Auto: AllUsers wenn Admin', 'Auto: AllUsers if admin')
$h = $h.Replace('Systemweit (UAC-Abfrage wenn n' + [char]0x00F6 + 'tig)', 'System-wide (UAC prompt if needed)')
$h = $h.Replace('Modul laden und pr' + [char]0x00FC + 'fen', 'Load and verify module')
$h = $h.Replace('Update pr' + [char]0x00FC + 'fen', 'Check for update')
$h = $h.Replace('Show 2 examples', 'Show 2 examples')

Copy-Item $file "$file.bak" -Force
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($file, $h, $enc)
Write-Host "Done."

$v = Get-Content $file -Raw
$cards = ([regex]::Matches($v,'psdb-st-func-card" id="f-')).Count
$nav   = ([regex]::Matches($v,"psstJump\('f-")).Count
$ov    = ([regex]::Matches($v,'psdb-st-ov-fn">')).Count
"VERIFY -> Cards:$cards Nav:$nav Overview:$ov"
