<#
.SYNOPSIS
    Builds a self-contained animated HTML replay from a setup event JSON-Lines file.

.DESCRIPTION
    Internal helper for the optional setup progress report. Reads the JSON-Lines stream produced by
    Write-sqmSetupEvent and writes ONE standalone .html file that animates the timeline: a phase
    pipeline, per-step visualizations (running-arrow copy, disk format, gears, node restart, AG
    replication, listener) and play/pause/scrub controls.

    The output is fully offline (no CDN, no external resources) so it opens by double-click or from a
    share. Returns the path of the written HTML file, or $null when no usable events were found.

.PARAMETER EventPath
    Path to the JSON-Lines event file written by Write-sqmSetupEvent.

.PARAMETER OutputPath
    Path of the HTML file to write. Default: the event file with extension .html.

.PARAMETER Title
    Report title. Default: 'SQL Server Setup'.

.PARAMETER Server
    Server/instance label shown in the header. Default: $env:COMPUTERNAME.
#>
function New-sqmSetupReport
{
	[CmdletBinding()]
	[OutputType([string])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$EventPath,

		[Parameter(Mandatory = $false)]
		[string]$OutputPath,

		[Parameter(Mandatory = $false)]
		[string]$Title = 'SQL Server Setup',

		[Parameter(Mandatory = $false)]
		[string]$Server = $env:COMPUTERNAME
	)

	if (-not (Test-Path -LiteralPath $EventPath)) {
		Write-Verbose "New-sqmSetupReport: Eventdatei nicht gefunden: $EventPath"
		return $null
	}

	# Keep only syntactically valid JSON lines (last line may be partial); reuse the raw text so we
	# do not depend on PowerShell array (un)wrapping when re-serializing.
	$validLines = [System.Collections.Generic.List[string]]::new()
	foreach ($line in (Get-Content -LiteralPath $EventPath -Encoding UTF8)) {
		$t = $line.Trim()
		if ($t -eq '') { continue }
		try { $null = $t | ConvertFrom-Json -ErrorAction Stop; $validLines.Add($t) } catch { }
	}
	if ($validLines.Count -eq 0) {
		Write-Verbose "New-sqmSetupReport: keine gueltigen Events in $EventPath"
		return $null
	}

	if (-not $OutputPath) { $OutputPath = [System.IO.Path]::ChangeExtension($EventPath, '.html') }

	$eventsJson = '[' + ($validLines -join ',') + ']'
	$generated  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

	# Minimal HTML-escape for the few text fields injected outside the JSON island.
	function _Esc([string]$s) { ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;') }

	$template = @'
<!DOCTYPE html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>@@TITLE@@ - Ablauf</title>
<style>
:root{--bg:#faf9f5;--card:#fff;--ink:#1f1e1b;--mut:#6b6a64;--bd:#e3e1d8;--blue:#378ADD;--green:#1D9E75;--amber:#BA7517;--red:#E24B4A}
@media(prefers-color-scheme:dark){:root{--bg:#1b1b19;--card:#252523;--ink:#ECEAE2;--mut:#9c9b93;--bd:#3a3a36}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font-family:Segoe UI,system-ui,sans-serif;font-size:15px;line-height:1.5}
.wrap{max-width:860px;margin:0 auto;padding:20px}
h1{font-size:20px;font-weight:500;margin:0 0 2px}
.sub{color:var(--mut);font-size:13px;margin-bottom:16px}
.pl{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:14px}
.chip{flex:1;min-width:92px;border:1px solid var(--bd);border-radius:8px;padding:7px 9px;font-size:12px;background:var(--card);color:var(--mut);display:flex;align-items:center;gap:6px;transition:.2s}
.chip .ico{width:9px;height:9px;border-radius:50%;background:var(--bd);flex:none}
.chip.done{border-color:var(--green);color:var(--green)} .chip.done .ico{background:var(--green)}
.chip.act{border-color:var(--blue);color:var(--blue)} .chip.act .ico{background:var(--blue);animation:bl 1.2s infinite}
.chip.err{border-color:var(--red);color:var(--red)} .chip.err .ico{background:var(--red)}
@keyframes bl{50%{opacity:.4}}
.stage{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:16px;min-height:210px}
.st-title{font-size:15px;margin-bottom:2px}.st-det{color:var(--mut);font-size:13px;min-height:18px}
.ctrl{display:flex;align-items:center;gap:10px;margin:14px 0}
button{font:inherit;background:var(--card);color:var(--ink);border:1px solid var(--bd);border-radius:8px;padding:6px 12px;cursor:pointer}
button:hover{border-color:var(--mut)}
input[type=range]{flex:1}
.log{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:10px 14px;max-height:200px;overflow:auto;font-size:13px;margin-top:14px}
.log .row{padding:2px 0;color:var(--mut)} .log .row.cur{color:var(--ink);font-weight:500}
.log .s-done{color:var(--green)} .log .s-error{color:var(--red)} .log .s-warn{color:var(--amber)}
.march{stroke-dasharray:8 8;animation:m .6s linear infinite}@keyframes m{to{stroke-dashoffset:-16}}
.spin{transform-box:fill-box;transform-origin:center;animation:sp 1s linear infinite}@keyframes sp{to{transform:rotate(360deg)}}
.fill{transform-box:fill-box;transform-origin:bottom;animation:fl 2.2s ease-in-out infinite}@keyframes fl{0%{transform:scaleY(0)}60%,100%{transform:scaleY(1)}}
.slide{animation:sl 1.4s ease-in-out infinite}@keyframes sl{0%{transform:translateX(-60px)}100%{transform:translateX(220px)}}
.pulse{animation:pu 1.1s infinite}@keyframes pu{50%{opacity:.4}}
text{font-family:Segoe UI,system-ui,sans-serif}
</style></head>
<body><div class="wrap">
<h1>@@TITLE@@</h1>
<div class="sub">Server @@SERVER@@ &middot; erstellt @@GENERATED@@</div>
<div class="pl" id="pl"></div>
<div class="stage"><div class="st-title" id="stTitle"></div><div class="st-det" id="stDet"></div>
<svg id="viz" width="100%" viewBox="0 0 680 150" role="img" aria-label="Schritt-Visualisierung"></svg></div>
<div class="ctrl">
<button id="btnPlay">Play</button><button id="btnRestart">Neu</button>
<input type="range" id="seek" min="0" value="0"><span id="pos" class="sub" style="margin:0"></span>
</div>
<div class="log" id="log"></div>
</div>
<script id="evdata" type="application/json">@@EVENTS@@</script>
<script>
var EV=JSON.parse(document.getElementById('evdata').textContent);
var PHASES=[["copy","Quellen"],["preinstall","PreInstall"],["dirs","Verzeichnisse"],["install","Installation"],["components","Komponenten"],["drivers","Treiber"],["postinstall","PostInstall"],["alwayson","AlwaysOn"]];
var present=PHASES.filter(function(p){return EV.some(function(e){return e.phase===p[0]})});
var idx=0,playing=false,timer=null;
var seek=document.getElementById('seek');seek.max=Math.max(0,EV.length-1);
function esc(s){return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
function phaseState(ph,upto){var anyDone=false,anyErr=false,anyAct=false,lastIsThis=(EV[upto]&&EV[upto].phase===ph);
 for(var j=0;j<=upto;j++){var x=EV[j];if(x.phase!==ph)continue;if(x.state==='error')anyErr=true;if(x.state==='done')anyDone=true;if(x.state==='start'||x.state==='progress')anyAct=true;}
 if(anyErr)return'err';if(lastIsThis&&EV[upto].state!=='done')return'act';if(anyDone)return'done';if(anyAct)return'act';return''}
function renderPipe(){var h='';present.forEach(function(p){var s=phaseState(p[0],idx);h+='<div class="chip '+s+'"><span class="ico"></span>'+p[1]+'</div>'});document.getElementById('pl').innerHTML=h}
function col(state){return state==='done'?'var(--green)':state==='error'?'var(--red)':state==='warn'?'var(--amber)':'var(--blue)'}
function box(x,y,w,t,sub){var s='<rect x="'+x+'" y="'+y+'" width="'+w+'" height="50" rx="8" fill="var(--card)" stroke="var(--bd)"/>';
 s+='<text x="'+(x+w/2)+'" y="'+(y+24)+'" font-size="13" text-anchor="middle" fill="var(--ink)">'+esc(t)+'</text>';
 if(sub)s+='<text x="'+(x+w/2)+'" y="'+(y+40)+'" font-size="11" text-anchor="middle" fill="var(--mut)">'+esc(sub)+'</text>';return s}
function arrow(x1,x2,y,c){return '<line x1="'+x1+'" y1="'+y+'" x2="'+x2+'" y2="'+y+'" stroke="'+c+'" stroke-width="2" class="march"/><path d="M'+(x2-6)+','+(y-4)+' L'+x2+','+y+' L'+(x2-6)+','+(y+4)+'" fill="none" stroke="'+c+'" stroke-width="2"/>'}
function renderViz(e){var v=e?e.viz:'',st=e?e.state:'',c=col(st),svg=document.getElementById('viz');if(!e){svg.innerHTML='';return}
 var h='';
 if(v==='flow-arrows'){h=box(40,50,150,'Quelle','Share')+box(490,50,150,'Ziel',e.node||'Server')+arrow(190,490,75,c)}
 else if(v==='disk-format'){h=box(40,50,150,'Laufwerk',e.node||'')+'<rect x="300" y="40" width="80" height="70" rx="6" fill="none" stroke="var(--bd)"/><rect x="302" y="42" width="76" height="66" class="fill" fill="'+c+'" opacity="0.5"/><text x="430" y="80" font-size="12" fill="var(--mut)">'+(e.pct>=0?e.pct+'%':'formatieren …')+'</text>'}
 else if(v==='node-restart'){h=box(265,45,150,e.node||'Node','Neustart …')+'<g class="spin"><path d="M340,30 a14,14 0 1 1 -12,8" fill="none" stroke="'+c+'" stroke-width="3"/><path d="M328,38 l-2,-9 l9,3 z" fill="'+c+'"/></g>'}
 else if(v==='data-replicate'){h=box(40,50,150,'Primary',e.node||'')+box(490,50,150,'Secondary','')+arrow(190,490,75,'var(--green)')+'<text x="340" y="65" font-size="11" text-anchor="middle" fill="var(--mut)">Seeding</text>'}
 else if(v==='listener'){h='<rect x="250" y="55" width="180" height="44" rx="22" fill="'+c+'" opacity="0.18" class="pulse"/><text x="340" y="82" font-size="14" text-anchor="middle" fill="'+c+'">'+esc(e.title||'Listener')+'</text>'}
 else if(v==='gears'){h='<g class="spin"><circle cx="340" cy="75" r="22" fill="none" stroke="'+c+'" stroke-width="6"/><circle cx="340" cy="75" r="6" fill="'+c+'"/></g><text x="340" y="125" font-size="12" text-anchor="middle" fill="var(--mut)">arbeitet …</text>'}
 else{h='<rect x="120" y="66" width="440" height="14" rx="7" fill="none" stroke="var(--bd)"/><rect x="120" y="66" width="120" height="14" rx="7" fill="'+c+'" opacity="0.6" class="slide"/>'}
 if(st==='done')h+='<path d="M610,30 l8,8 l16,-18" fill="none" stroke="var(--green)" stroke-width="3"/>';
 svg.innerHTML=h}
function renderLog(){var h='';for(var i=0;i<EV.length;i++){var e=EV[i];h+='<div class="row '+(i===idx?'cur':'')+' s-'+e.state+'">'+esc(e.title||(e.phase+'/'+e.step))+(e.detail?' — '+esc(e.detail):'')+'</div>'}var l=document.getElementById('log');l.innerHTML=h;var cur=l.querySelector('.cur');if(cur)cur.scrollIntoView({block:'nearest'})}
function render(){var e=EV[idx];document.getElementById('stTitle').textContent=e?(e.title||e.phase):'';document.getElementById('stDet').textContent=e?(e.detail||''):'';document.getElementById('pos').textContent=(idx+1)+' / '+EV.length;seek.value=idx;renderPipe();renderViz(e);renderLog()}
function step(){if(idx<EV.length-1){idx++;render()}else{pause()}}
function play(){if(idx>=EV.length-1)idx=0;playing=true;document.getElementById('btnPlay').textContent='Pause';timer=setInterval(step,900)}
function pause(){playing=false;document.getElementById('btnPlay').textContent='Play';if(timer)clearInterval(timer)}
document.getElementById('btnPlay').onclick=function(){playing?pause():play()};
document.getElementById('btnRestart').onclick=function(){pause();idx=0;render()};
seek.oninput=function(){pause();idx=parseInt(seek.value,10)||0;render()};
render();
</script></body></html>
'@

	$html = $template.
		Replace('@@EVENTS@@', $eventsJson).
		Replace('@@TITLE@@', (_Esc $Title)).
		Replace('@@SERVER@@', (_Esc $Server)).
		Replace('@@GENERATED@@', (_Esc $generated))

	try {
		$dir = Split-Path -Path $OutputPath -Parent
		if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
		[System.IO.File]::WriteAllText($OutputPath, $html, (New-Object System.Text.UTF8Encoding($false)))
		return $OutputPath
	}
	catch {
		Write-Verbose "New-sqmSetupReport: Schreiben fehlgeschlagen: $($_.Exception.Message)"
		return $null
	}
}
