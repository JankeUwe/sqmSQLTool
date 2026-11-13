<#
    Get-sqmProviderInventoryHtml.ps1  -  Private Hilfsfunktionen fuer Get-sqmProviderInventory
    ===========================================================================
    Funktionen:
      Get-sqmProviderInventoryViewerTemplate - HTML-Vorlage mit eingebautem Viewer (reines JavaScript)
      ConvertTo-sqmProviderInventoryHtml     - Setzt Scan-JSON in die Vorlage ein

    Der Viewer braucht weder PowerShell noch Excel noch Internet. Er liest die eingebetteten
    Scan-Daten, laedt weitere HTML/JSON/CSV-Dateien per Drag and Drop, fuehrt Zuordnung und
    Security-Filter aus und exportiert CSV, xlsx und eine Provider-HTML ohne Security-Daten.
    ===========================================================================
#>

function Get-sqmProviderInventoryViewerTemplate
{
	[CmdletBinding()]
	[OutputType([string])]
	param ()
	return @'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>@@TITLE@@</title>
<style>
:root { --bg:#060f20; --panel:#0d1f38; --panel2:#0b1e3d; --line:#1e3a5f; --line2:#14283f; --txt:#e2e8f0; --mute:#94a8c0; --acc:#5dade2; --ok:#2ecc71; --warn:#f1c40f; --crit:#e74c3c; }
* { box-sizing: border-box; }
body { font-family: 'Segoe UI', Arial, sans-serif; background: var(--bg); color: var(--txt); font-size: 13px; margin: 0; }
.hdr { background: linear-gradient(160deg,#060f20 0%,#0b1e3d 100%); padding: 20px 32px; border-bottom: 1px solid var(--line); }
.hdr h1 { margin: 0 0 4px 0; font-size: 22px; color: var(--acc); }
.hdr .sub { color: var(--mute); font-size: 13px; }
.hdr .ref { color: var(--acc); font-size: 12px; margin-top: 6px; }
.bar { padding: 12px 32px; background: var(--panel2); border-bottom: 1px solid var(--line); display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: center; }
.bar .grp { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.bar .sep { width: 1px; align-self: stretch; background: var(--line); }
button, .btn { background: #123a63; color: var(--txt); border: 1px solid #2d6aa3; border-radius: 4px; padding: 5px 10px; font: inherit; cursor: pointer; }
button:hover, .btn:hover { background: #1a4f84; }
button:disabled { opacity: .4; cursor: default; }
button.sec { background: #3b2a0f; border-color: #8a6a1f; }
button.sec:hover { background: #55401a; }
label.chk { color: var(--mute); cursor: pointer; user-select: none; }
label.chk input { vertical-align: middle; margin-right: 4px; }
#drop { border: 1px dashed var(--line); border-radius: 4px; padding: 5px 12px; color: var(--mute); }
#drop.over { border-color: var(--acc); color: var(--acc); background: rgba(93,173,226,.08); }
.tabs { padding: 8px 32px 0 32px; display: flex; flex-wrap: wrap; gap: 2px; border-bottom: 1px solid var(--line); }
.tab { padding: 7px 12px; color: var(--mute); cursor: pointer; border: 1px solid transparent; border-bottom: none; border-radius: 4px 4px 0 0; }
.tab:hover { color: var(--txt); }
.tab.on { color: var(--acc); background: var(--panel); border-color: var(--line); }
.tab.secTab { color: #e0b050; }
.tab .n { color: var(--mute); font-size: 11px; margin-left: 4px; }
.wrap { padding: 16px 32px 24px 32px; }
.tools { display: flex; gap: 10px; align-items: center; margin-bottom: 10px; flex-wrap: wrap; }
.tools input[type=text] { background: var(--panel); color: var(--txt); border: 1px solid var(--line); border-radius: 4px; padding: 5px 8px; width: 280px; font: inherit; }
.tools .cnt { color: var(--mute); }
.tblwrap { overflow: auto; max-height: 68vh; border: 1px solid var(--line); border-radius: 4px; }
table { border-collapse: collapse; background: var(--panel); min-width: 100%; }
th { position: sticky; top: 0; background: var(--panel2); color: var(--mute); font-size: 11px; font-weight: 600; text-transform: uppercase; padding: 8px 10px; text-align: left; border-bottom: 1px solid var(--line); white-space: nowrap; cursor: pointer; user-select: none; }
th:hover { color: var(--acc); }
td { padding: 6px 10px; border-bottom: 1px solid var(--line2); white-space: nowrap; max-width: 420px; overflow: hidden; text-overflow: ellipsis; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
tr:hover td { background: rgba(45,134,193,0.07); }
td input[type=text] { background: #08162b; color: var(--txt); border: 1px solid var(--line); border-radius: 3px; padding: 3px 6px; font: inherit; width: 150px; }
td input[type=text].wide { width: 220px; }
td input.empty { border-color: #8a6a1f; background: #231c0b; }
.cards { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 16px; }
.card { background: var(--panel); border: 1px solid var(--line); border-radius: 6px; padding: 10px 16px; min-width: 130px; }
.card .v { font-size: 22px; color: var(--acc); font-weight: 600; }
.card .l { color: var(--mute); font-size: 11px; text-transform: uppercase; }
.lvl-FEHLER, .lvl-FEHLT { color: var(--crit); font-weight: 600; }
.lvl-ZUORDNUNG, .lvl-LUECKE, .lvl-ALT { color: var(--warn); }
.lvl-HINWEIS { color: var(--mute); }
.note { background: var(--panel); border: 1px solid var(--line); border-left: 3px solid var(--warn); padding: 8px 12px; margin-bottom: 12px; color: var(--mute); }
.note b { color: var(--txt); }
.footer { padding: 14px 32px; border-top: 1px solid var(--line); color: var(--mute); font-size: 12px; }
.footer a { color: var(--acc); text-decoration: none; }
.more { margin: 10px 0; }
.empty-hint { color: var(--mute); padding: 30px 0; }
</style>
</head>
<body>
<div class="hdr">
  <h1>@@TITLE@@</h1>
  <div class="sub" id="subline"></div>
  <div class="ref">@@REF@@</div>
</div>
<div class="bar" id="bar">
  <div class="grp">
    <span id="drop">HTML/JSON/CSV hier ablegen</span>
    <label class="btn" for="files">Dateien laden ...</label>
    <input type="file" id="files" multiple accept=".html,.htm,.json,.csv" style="display:none">
  </div>
  <div class="sep"></div>
  <div class="grp">
    <label class="chk"><input type="checkbox" id="optAnon">Server anonymisieren</label>
    <label class="chk"><input type="checkbox" id="optSec">Security-Daten anzeigen</label>
    <label class="chk" id="optSysWrap" style="display:none"><input type="checkbox" id="optSys">System/sysadmin einbeziehen</label>
  </div>
  <div class="sep"></div>
  <div class="grp">
    <button id="bCsv" title="Aktuellen Tab als CSV (UTF-8, Semikolon)">CSV (Tab)</button>
    <button id="bXlsx" title="Alle Provider-Tabs als Excel-Datei, ohne Security-Daten">Excel Provider</button>
    <button id="bHtmlProv" title="Reduzierte HTML-Datei ohne Security-Daten zum Weitergeben">Provider-HTML</button>
  </div>
  <div class="sep"></div>
  <div class="grp">
    <button id="bXlsxSec" class="sec" title="Nur intern: Logins, Rechte, Rollen" disabled>Excel Security</button>
    <button id="bHtmlFull" class="sec" title="Nur intern: alle gelandenen Scans samt Security-Daten und Zuordnung in einer Datei">Sammeldatei</button>
    <button id="bMap" title="Zuordnung als CSV">Zuordnung CSV</button>
    <button id="bRep" title="Pruefbericht als Textdatei">Pruefbericht</button>
    <button id="bKey" class="sec" title="Schluessel Original zu Kennung. Nicht weitergeben." disabled>Anonym-Schluessel</button>
  </div>
</div>
<div class="tabs" id="tabs"></div>
<div class="wrap" id="app"></div>
<div class="footer">
  sqmSQLTool &nbsp;|&nbsp; dtcSoftware / Uwe Janke &nbsp;|&nbsp; <a href="https://www.powershelldba.de">www.powershelldba.de</a>
  &nbsp;&nbsp;&ndash;&nbsp;&nbsp; @@STAMP@@
</div>
<script type="application/json" id="scan-data">@@SCANDATA@@</script>
<script type="application/json" id="mapping-data">@@MAPDATA@@</script>
<script>
(function () {
'use strict';

var MAPCOLS = ['Anwendung', 'Obergruppe', 'Schutzbedarf', 'Kritikalitaet', 'RPO', 'RTO', 'Wartungsfenster', 'Ansprechpartner', 'Bemerkung'];
var NZ = 'NICHT ZUGEORDNET';
var MAX_AGE_DAYS = 30;
var PROVIDER_TABS = ['Zusammenfassung', 'Zuordnung', 'Server', 'Platten', 'Datentraeger', 'SQL-Instanzen', 'Datenbanken', 'Dateien', 'Abhaengigkeiten', 'HA-DR', 'Komponenten', 'Agent-Jobs', 'Pruefbericht'];
var SEC_TABS = ['Sec-Zusammenfassung', 'Logins', 'Server-Rechte', 'DB-User', 'DB-Rollen', 'Rollenmitglieder', 'DB-Berechtigungen'];
var SEC_KEYS = ['logins', 'server_permissions', 'db_users', 'db_roles', 'db_role_members', 'db_permissions'];

var S = { scans: [], mapping: {}, csvHosts: {}, notes: [], anon: false, secShow: false, secSys: false, tab: 'Zusammenfassung',
          filter: '', sortCol: null, sortDir: 1, limit: 300, model: null, dirty: false, sel: {}, mapFilter: '' };

/* ---------- helpers ---------- */
function $(id) { return document.getElementById(id); }
function esc(v) { return String(v === null || v === undefined ? '' : v).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
function g(o) { for (var i = 1; i < arguments.length; i++) { if (o === null || o === undefined) return null; o = o[arguments[i]]; } return (o === undefined) ? null : o; }
function asList(v) { if (v === null || v === undefined) return []; if (Array.isArray(v)) return v.filter(function (x) { return x !== null && x !== undefined; }); return [v]; }
function isT(v) { return v === true || v === 1 || v === 'True' || v === 'true'; }
function B(v) { return (v === null || v === undefined) ? null : (isT(v) ? 'ja' : 'nein'); }
function rnd(v, d) { if (v === null || v === undefined || v === '') return null; var n = Number(v); if (!isFinite(n)) return null; var f = Math.pow(10, d === undefined ? 1 : d); return Math.round(n * f) / f; }
function gb(mb, d) { if (mb === null || mb === undefined || mb === '') return null; return rnd(Number(mb) / 1024, d === undefined ? 1 : d); }
function mn(sec, d) { if (sec === null || sec === undefined || sec === '') return null; return rnd(Number(sec) / 60, d === undefined ? 1 : d); }
function sum(rows, key) { var t = 0; rows.forEach(function (r) { var n = Number(r[key]); if (isFinite(n) && r[key] !== null && r[key] !== '') t += n; }); return t; }
function joinU(arr) { var seen = {}, out = []; asList(arr).forEach(function (x) { if (x === null || x === '' || seen[x]) return; seen[x] = 1; out.push(x); }); return out.join('; '); }
function up(s) { return String(s === null || s === undefined ? '' : s).toUpperCase(); }
function trimNul(s) { return String(s).replace(/^[\u0000\s]+|[\u0000\s]+$/g, ''); }
function safeJson(o) { return JSON.stringify(o).replace(/</g, '\\u003c'); }
function pad(n) { return (n < 10 ? '0' : '') + n; }
function stamp() { var d = new Date(); return d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()); }
function cmpVal(a, b) {
  var na = (typeof a === 'number'), nb = (typeof b === 'number');
  if (a === null || a === undefined || a === '') return (b === null || b === undefined || b === '') ? 0 : 1;
  if (b === null || b === undefined || b === '') return -1;
  if (na && nb) return a - b;
  return String(a).localeCompare(String(b), 'de', { numeric: true, sensitivity: 'base' });
}

/* ---------- load ---------- */
function ingestScans(list, label) {
  list.forEach(function (sc) {
    var hn = g(sc, 'host', 'computer_name');
    if (!hn) { S.notes.push({ Stufe: 'FEHLER', Server: label, Meldung: 'Kein host.computer_name, Eintrag ist kein gueltiger Scan.' }); return; }
    var key = up(hn), replaced = false;
    for (var i = 0; i < S.scans.length; i++) {
      if (up(S.scans[i].host.computer_name) === key) {
        if (String(sc.scan_started) > String(S.scans[i].scan_started)) { S.scans[i] = sc; }
        S.notes.push({ Stufe: 'HINWEIS', Server: hn, Meldung: 'Mehrere Scans, der aeltere wurde ignoriert (' + label + ').' });
        replaced = true; break;
      }
    }
    if (!replaced) S.scans.push(sc);
  });
  S.scans.sort(function (a, b) { return cmpVal(a.host.computer_name, b.host.computer_name); });
}
function ingestMapping(obj, overwrite) {
  Object.keys(obj || {}).forEach(function (k) {
    var key = up(k), cur = S.mapping[key] || (S.mapping[key] = {});
    MAPCOLS.forEach(function (c) { var v = obj[k][c]; if (v !== undefined && v !== null && String(v) !== '' && (overwrite || !cur[c])) cur[c] = String(v); });
  });
}
function parseCsv(text) {
  if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
  var delim = (text.split('\n')[0].split(';').length >= text.split('\n')[0].split(',').length) ? ';' : ',';
  var rows = [], row = [], f = '', q = false, i, ch;
  for (i = 0; i < text.length; i++) {
    ch = text.charAt(i);
    if (q) { if (ch === '"') { if (text.charAt(i + 1) === '"') { f += '"'; i++; } else q = false; } else f += ch; }
    else if (ch === '"') q = true;
    else if (ch === delim) { row.push(f); f = ''; }
    else if (ch === '\n') { row.push(f); rows.push(row); row = []; f = ''; }
    else if (ch !== '\r') f += ch;
  }
  if (f !== '' || row.length) { row.push(f); rows.push(row); }
  return rows;
}
function loadText(name, text) {
  var lower = name.toLowerCase(), m;
  if (/\.csv$/.test(lower)) {
    var rows = parseCsv(text);
    if (!rows.length) return;
    var hd = rows[0].map(function (x) { return x.trim(); }), si = hd.indexOf('Server');
    if (si < 0) { S.notes.push({ Stufe: 'FEHLER', Server: name, Meldung: 'CSV ohne Spalte "Server", nicht als Zuordnung lesbar.' }); return; }
    var obj = {}, n = 0;
    rows.slice(1).forEach(function (r) {
      var srv = (r[si] || '').trim(); if (!srv) return;
      var o = {}; hd.forEach(function (h, idx) { if (MAPCOLS.indexOf(h) >= 0) o[h] = r[idx]; });
      obj[srv] = o; S.csvHosts[up(srv)] = srv; n++;
    });
    ingestMapping(obj, true);
    S.notes.push({ Stufe: 'HINWEIS', Server: name, Meldung: 'Zuordnung gelesen: ' + n + ' Server.' });
    return;
  }
  if (/\.html?$/.test(lower)) {
    m = /<script type="application\/json" id="scan-data">([\s\S]*?)<\/script>/.exec(text);
    if (!m) { S.notes.push({ Stufe: 'FEHLER', Server: name, Meldung: 'Keine Scan-Daten in der HTML-Datei gefunden.' }); return; }
    ingestScans(asList(JSON.parse(m[1])), name);
    var mm = /<script type="application\/json" id="mapping-data">([\s\S]*?)<\/script>/.exec(text);
    if (mm) { try { ingestMapping(JSON.parse(mm[1]), false); } catch (e) { S.notes.push({ Stufe: 'HINWEIS', Server: name, Meldung: 'Zuordnung in der Datei nicht lesbar.' }); } }
    return;
  }
  ingestScans(asList(JSON.parse(text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text)), name);
}
function loadFiles(fileList) {
  var arr = Array.prototype.slice.call(fileList), left = arr.length;
  if (!left) return;
  arr.forEach(function (f) {
    var rd = new FileReader();
    rd.onload = function () { try { loadText(f.name, String(rd.result)); } catch (e) { S.notes.push({ Stufe: 'FEHLER', Server: f.name, Meldung: 'Datei nicht lesbar: ' + e.message }); } if (--left === 0) { S.dirty = true; S.model = null; renderAll(); } };
    rd.onerror = function () { S.notes.push({ Stufe: 'FEHLER', Server: f.name, Meldung: 'Datei nicht lesbar.' }); if (--left === 0) { S.model = null; renderAll(); } };
    rd.readAsText(f, 'utf-8');
  });
}

/* ---------- model ---------- */
function mapVal(sc, col, scanKey) {
  var m = S.mapping[up(sc.host.computer_name)], v = m ? m[col] : '';
  if (!v && scanKey) v = g(sc, 'mapping', scanKey);
  return v ? String(v) : '';
}
function hasSecurity(sc) { return asList(sc.instances).some(function (i) { return i.logins !== null && i.logins !== undefined; }); }

function build() {
  var scans = S.scans, byHost = {}, rep = S.notes.slice(), now = Date.now();
  scans.forEach(function (s) { byHost[up(s.host.computer_name)] = s; });
  function R(l, s, t) { rep.push({ Stufe: l, Server: s, Meldung: t }); }

  Object.keys(S.csvHosts).forEach(function (k) { if (!byHost[k]) R('FEHLT', S.csvHosts[k], 'In der Zuordnung, aber kein Scan vorhanden.'); });
  scans.forEach(function (s) {
    var hn = s.host.computer_name;
    if (!mapVal(s, 'Anwendung', 'application')) R('ZUORDNUNG', hn, 'Anwendung fehlt (' + NZ + ').');
    if (!mapVal(s, 'Obergruppe', 'parent_group')) R('ZUORDNUNG', hn, 'Obergruppe fehlt (' + NZ + ').');
    if (Object.keys(S.csvHosts).length && !S.csvHosts[up(hn)]) R('ZUORDNUNG', hn, 'Server fehlt in der geladenen Zuordnungs-CSV.');
    var age = (now - new Date(s.scan_started).getTime()) / 86400000;
    if (age > MAX_AGE_DAYS) R('ALT', hn, 'Scan ist ' + Math.round(age) + ' Tage alt (' + s.scan_started + ').');
    if (String(s.schema_version) !== '1.0') R('HINWEIS', hn, 'Unbekannte Schema-Version ' + s.schema_version + '.');
    asList(g(s, 'host', 'errors')).forEach(function (e) { R('LUECKE', hn, 'Host ' + e.section + ': ' + e.message); });
    if (!asList(s.instances).length) R('HINWEIS', hn, 'Keine SQL-Instanz im Scan.');
    asList(s.instances).forEach(function (i) {
      if (!isT(i.connected)) { R('FEHLER', hn, 'Instanz ' + i.connect_target + ' nicht erreichbar: ' + i.connect_error); return; }
      asList(i.errors).forEach(function (e) { R('LUECKE', hn, 'Instanz ' + i.instance_name + ' ' + e.section + ': ' + e.message); });
      var up_h = g(i, 'server', 'uptime_hours');
      if (up_h !== null && up_h < 168) R('HINWEIS', hn, 'Instanz ' + i.instance_name + ': SQL-Dienst laeuft erst ' + up_h + ' h, Lastwerte sind nicht belastbar.');
    });
  });

  var sv = [], dk = [], hw = [], ins = [], db = [], fl = [], dep = [], ha = [], cp = [], jb = [], anyJobs = false, reportedPartners = {};
  scans.forEach(function (s) {
    var h = s.host, hn = h.computer_name, cpu = h.cpu || {}, insts = asList(s.instances);
    var app = mapVal(s, 'Anwendung', 'application') || NZ, grp = mapVal(s, 'Obergruppe', 'parent_group') || NZ;
    var osr = h.os || {};
    sv.push({
      'Server': hn, 'Anwendung': app, 'Obergruppe': grp, 'Schutzbedarf': mapVal(s, 'Schutzbedarf'), 'Kritikalitaet': mapVal(s, 'Kritikalitaet'),
      'RPO': mapVal(s, 'RPO'), 'RTO': mapVal(s, 'RTO'), 'Wartungsfenster': mapVal(s, 'Wartungsfenster'), 'Ansprechpartner': mapVal(s, 'Ansprechpartner'), 'Bemerkung': mapVal(s, 'Bemerkung'),
      'FQDN': h.fqdn, 'Domaene': h.domain, 'Domaenenmitglied': B(h.part_of_domain), 'Virtuell': B(h.is_virtual), 'Hersteller': h.manufacturer, 'Modell': h.model,
      'Betriebssystem': osr.caption, 'OS-Version': osr.version, 'OS-Build': osr.build, 'OS-Edition': osr.edition_id, 'Installationsart': osr.installation_type, 'Architektur': osr.architecture,
      'OS-Release': osr.display_version, 'Letzter Hotfix': g(h, 'last_hotfix', 'installed_on'),
      'Sockets': cpu.sockets, 'Kerne': cpu.cores, 'Logische CPUs': cpu.logical_processors, 'CPU-Modell': cpu.model ? String(cpu.model).trim() : null,
      'RAM GB': gb(h.memory_mb, 1), 'Pagefile MB': h.pagefile_configured_mb, 'Energieplan': h.power_plan, 'Letzter Boot': h.last_boot, 'Zeitzone': h.time_zone,
      'IPs': joinU(asList(h.ip_addresses).map(function (x) { return asList(x.ip).filter(function (ip) { return /^\d+\.\d+\.\d+\.\d+$/.test(ip); }); }).reduce(function (a, b) { return a.concat(b); }, [])),
      'Anzahl Instanzen': insts.length, 'Scan-Zeitpunkt': s.scan_started, 'Scan-Dauer s': s.scan_duration_sec
    });
    asList(h.volumes).forEach(function (v) {
      var sqlMb = 0, iops = 0, mbps = 0, rl = null, wl = null, cnt = 0;
      insts.forEach(function (i) {
        asList(i.volume_io).forEach(function (vi) {
          if (vi.volume === v.name) {
            sqlMb += Number(vi.sql_files_mb) || 0; iops += Number(vi.avg_iops_since_start) || 0; mbps += Number(vi.avg_mb_per_sec_since_start) || 0; cnt += Number(vi.sql_file_count) || 0;
            if (vi.avg_read_latency_ms !== null && vi.avg_read_latency_ms !== undefined && (rl === null || vi.avg_read_latency_ms > rl)) rl = vi.avg_read_latency_ms;
            if (vi.avg_write_latency_ms !== null && vi.avg_write_latency_ms !== undefined && (wl === null || vi.avg_write_latency_ms > wl)) wl = vi.avg_write_latency_ms;
          }
        });
      });
      dk.push({
        'Server': hn, 'Obergruppe': grp, 'Laufwerk': v.name, 'Label': v.label, 'Dateisystem': v.file_system, 'Blockgroesse B': v.block_size,
        'Groesse GB': v.size_gb, 'Belegt GB': v.used_gb, 'Frei GB': v.free_gb, 'Belegt %': v.size_gb ? rnd(100 * v.used_gb / v.size_gb, 1) : null,
        'SQL-Dateien GB': cnt > 0 ? gb(sqlMb, 1) : null, 'SQL-Dateien Anzahl': cnt > 0 ? cnt : null,
        'IOPS avg (seit SQL-Start)': cnt > 0 ? rnd(iops, 1) : null, 'MB/s avg': cnt > 0 ? rnd(mbps, 2) : null, 'Read-Latenz ms': rl, 'Write-Latenz ms': wl
      });
    });
    asList(h.physical_disks).forEach(function (p) { hw.push({ 'Server': hn, 'Quelle': 'PhysicalDisk', 'Bezeichnung': p.friendly_name, 'Typ': p.media_type, 'Bus': p.bus_type, 'Groesse GB': p.size_gb }); });
    if (!asList(h.physical_disks).length) asList(h.disk_drives).forEach(function (d) { hw.push({ 'Server': hn, 'Quelle': 'DiskDrive', 'Bezeichnung': d.model, 'Typ': d.media_type, 'Bus': d['interface'], 'Groesse GB': d.size_gb }); });
    asList(h.sql_services).forEach(function (x) { cp.push({ 'Server': hn, 'Instanz': null, 'Typ': 'SQL-Dienst', 'Name': x.display_name, 'Detail': x.state + ' / ' + x.start_mode, 'Konto': x.account }); });
    asList(h.third_party_services).forEach(function (x) { cp.push({ 'Server': hn, 'Instanz': null, 'Typ': 'Dienst (Fremdsoftware)', 'Name': x.display_name, 'Detail': x.state, 'Konto': x.account }); });

    insts.forEach(function (i) {
      if (!isT(i.connected)) return;
      var sq = i.server || {}, ld = i.load || {}, dbs = asList(i.databases), cfg = i.config || {};
      var userDbs = dbs.filter(function (d) { return d.name !== 'tempdb'; });
      var tcp = asList(i.tcp_settings), fixed = null, dyn = null;
      tcp.forEach(function (t) { if (/IPAll$/.test(t.registry_key || '')) { if (t.value_name === 'TcpPort' && !fixed && t.value_data) fixed = t.value_data; if (t.value_name === 'TcpDynamicPorts' && !dyn && t.value_data) dyn = t.value_data; } });
      var port = fixed ? trimNul(fixed) : (dyn ? trimNul(dyn) + ' (dynamisch)' : null);
      if (port && !port.replace('(dynamisch)', '').trim()) port = null;
      var haI = i.high_availability || {}, agRows = asList(haI.availability_replicas);
      var agNames = joinU(agRows.map(function (r) { return r.ag_name; }));
      var agLocal = joinU(agRows.filter(function (r) { return isT(r.is_local); }).map(function (r) { return r.ag_name + ': ' + r.role_desc; }));
      var agPartners = joinU(agRows.filter(function (r) { return !isT(r.is_local); }).map(function (r) { return r.replica_server_name; }));
      var agDb = {};
      asList(haI.availability_databases).forEach(function (a) { agDb[a.database_name] = a.ag_name; });
      agRows.forEach(function (pn) {
        var ph = up(String(pn.replica_server_name || '').split('\\')[0].split('.')[0]);
        if (ph && !byHost[ph] && !reportedPartners[hn + '|' + ph]) { reportedPartners[hn + '|' + ph] = 1; R('FEHLT', ph, 'AG-Partnerknoten von ' + hn + ' (AG ' + pn.ag_name + ') ist nicht gescannt.'); }
      });
      var comp = i.components || {}, sumJ = i.agent_jobs_summary || {};
      ins.push({
        'Server': hn, 'Anwendung': app, 'Obergruppe': grp, 'Instanz': i.instance_name,
        'SQL-Version': sq.product_version, 'Major': sq.major_version, 'Patchlevel': sq.product_level, 'CU': sq.product_update_level, 'Edition': sq.edition,
        'Collation': sq.collation, 'Lizenz-Kerne (sichtbar)': sq.licensed_cores_visible_online, 'CPU gesamt': sq.cpu_count,
        'RAM Server MB': sq.physical_memory_mb, 'Max Memory MB': cfg['max server memory (MB)'], 'Min Memory MB': cfg['min server memory (MB)'], 'MAXDOP': cfg['max degree of parallelism'],
        'Cost Threshold': cfg['cost threshold for parallelism'], 'Backup Compression Default': cfg['backup compression default'],
        'Cluster': B(sq.is_clustered), 'AlwaysOn aktiv': B(sq.is_hadr_enabled), 'Nur Windows-Auth': B(sq.windows_auth_only), 'Volltext': B(sq.fulltext_installed),
        'TCP-Port': port, 'Uptime h': sq.uptime_hours, 'SQL-Start': sq.sqlserver_start_time,
        'SQL CPU avg %': ld.sql_cpu_avg_pct, 'SQL CPU p95 %': ld.sql_cpu_p95_pct, 'SQL CPU max %': ld.sql_cpu_max_pct, 'Gesamt CPU p95 %': ld.total_cpu_p95_pct, 'CPU Historie min': ld.cpu_samples_minutes,
        'Page Life Expectancy s': ld.page_life_expectancy_sec, 'Memory aktuell MB': ld.total_server_memory_mb, 'Memory Ziel MB': ld.target_server_memory_mb,
        'Batch Requests/s (Messung)': ld.batch_requests_per_sec_sampled, 'Batch Requests/s (avg)': ld.batch_requests_per_sec_avg_since_start,
        'Transaktionen/s (Messung)': ld.transactions_per_sec_sampled, 'Transaktionen/s (avg)': ld.transactions_per_sec_avg_since_start, 'Verbindungen': ld.user_connections,
        'Anzahl DBs (ohne tempdb)': userDbs.length, 'DB-Daten GB': gb(sum(userDbs, 'data_size_mb'), 1),
        'Agent-Jobs': sumJ.total, 'Agent-Jobs aktiv': sumJ.enabled, 'Linked Server': asList(i.linked_servers).length,
        'DB-Mail-Profile': comp.database_mail_profiles, 'Credentials': asList(comp.credentials).length, 'Proxies': asList(comp.proxies).length,
        'Availability Group': agNames, 'AG-Rolle (lokal)': agLocal, 'AG-Partnerknoten': agPartners,
        'xp_cmdshell': cfg['xp_cmdshell'], 'CLR aktiv': cfg['clr enabled']
      });
      dbs.forEach(function (d) {
        var b = d.backup || {}, bf = b.full || {}, bd = b.diff || {}, bl = b.log || {};
        db.push({
          'Server': hn, 'Anwendung': app, 'Obergruppe': grp, 'Instanz': i.instance_name, 'Datenbank': d.name, 'Availability Group': agDb[d.name] || null, 'Status': d.state,
          'Compat': d.compatibility_level, 'Recovery': d.recovery_model, 'Collation': d.collation, 'Owner': d.owner,
          'Daten GB': gb(d.data_size_mb, 2), 'Daten belegt GB': gb(d.data_used_mb, 2), 'Log GB': gb(d.log_size_mb, 2), 'Log belegt %': d.log_used_pct,
          'Dateien': d.file_count, 'Tabellen': d.table_count, 'Wachstum MB/Monat': d.growth_mb_per_month, 'Full-Groessen MB/Monat': d.full_backup_size_history_mb,
          'TDE': B(d.is_encrypted_tde), 'Always Encrypted Keys': d.always_encrypted_keys, 'CLR-Assemblies': d.clr_assemblies, 'Containment': d.containment, 'Read-Only': B(d.is_read_only), 'Snapshot': B(d.is_snapshot),
          'Full letzte': bf.last_finish, 'Full Anzahl': bf.count_in_window, 'Full avg min': mn(bf.avg_duration_sec), 'Full max min': mn(bf.max_duration_sec),
          'Full avg GB': gb(bf.avg_size_mb, 2), 'Full komprimiert GB': gb(bf.avg_compressed_mb, 2), 'Full Ziel': bf.last_target,
          'Diff letzte': bd.last_finish, 'Diff avg min': mn(bd.avg_duration_sec),
          'Log letzte': bl.last_finish, 'Log Anzahl': bl.count_in_window, 'Log avg min': mn(bl.avg_duration_sec),
          'Publisher': B(d.is_published), 'Subscriber': B(d.is_subscribed), 'Merge-Publisher': B(d.is_merge_published), 'Distributor': B(d.is_distributor), 'CDC': B(d.cdc_enabled), 'Service Broker': B(d.service_broker)
        });
      });
      asList(i.files).forEach(function (f) {
        fl.push({ 'Server': hn, 'Instanz': i.instance_name, 'Datenbank': f.database, 'Logischer Name': f.logical_name, 'Typ': f.type, 'Pfad': f.path, 'Laufwerk': f.volume, 'Groesse MB': f.size_mb, 'Growth': f.growth, 'Growth in %': B(f.percent_growth), 'Max Size': f.max_size });
      });
      asList(i.linked_servers).forEach(function (ls) {
        dep.push({ 'Typ': 'Linked Server', 'Server': hn, 'Instanz': i.instance_name, 'Quelle': null, 'Ziel': ls.name, 'Detail': ls.provider + ' / ' + ls.data_source, 'Info': 'Login-Mappings: ' + ls.login_mappings + ', feste Remote-Logins: ' + ls.fixed_remote_logins });
      });
      asList(i.cross_database_refs).forEach(function (x) {
        if (x.ref_server) dep.push({ 'Typ': 'Cross-Server-Referenz', 'Server': hn, 'Instanz': i.instance_name, 'Quelle': x.database, 'Ziel': x.ref_server, 'Detail': x.ref_database, 'Info': 'Referenzen: ' + x.ref_count });
        else dep.push({ 'Typ': 'Cross-DB-Referenz', 'Server': hn, 'Instanz': i.instance_name, 'Quelle': x.database, 'Ziel': x.ref_database, 'Detail': null, 'Info': 'Referenzen: ' + x.ref_count });
      });
      dbs.forEach(function (d) {
        if (isT(d.is_published) || isT(d.is_merge_published)) dep.push({ 'Typ': 'Replikation (Publisher)', 'Server': hn, 'Instanz': i.instance_name, 'Quelle': d.name, 'Ziel': null, 'Detail': null, 'Info': null });
        if (isT(d.is_subscribed)) dep.push({ 'Typ': 'Replikation (Subscriber)', 'Server': hn, 'Instanz': i.instance_name, 'Quelle': d.name, 'Ziel': null, 'Detail': null, 'Info': null });
        if (isT(d.is_distributor)) dep.push({ 'Typ': 'Replikation (Distributor)', 'Server': hn, 'Instanz': i.instance_name, 'Quelle': d.name, 'Ziel': null, 'Detail': null, 'Info': null });
      });
      if (i.agent_jobs) {
        anyJobs = true;
        asList(i.agent_jobs).forEach(function (j) {
          jb.push({ 'Server': hn, 'Instanz': i.instance_name, 'Job': j.name, 'Aktiv': B(j.enabled), 'Owner': j.owner, 'Kategorie': j.category, 'Schritte': j.step_count, 'Subsysteme': j.subsystems,
                    'Proxy genutzt': B(j.uses_proxy), 'Zeitplan': j.schedules, 'Letzter Lauf': j.last_run, 'Dauer avg s': j.avg_duration_sec, 'Fehlschlaege (Historie)': j.failures_in_history, 'Externe Referenzen': j.external_refs });
          if (j.external_refs) dep.push({ 'Typ': 'Agent-Job extern', 'Server': hn, 'Instanz': i.instance_name, 'Quelle': j.name, 'Ziel': j.external_refs, 'Detail': j.subsystems, 'Info': null });
        });
      }
      asList(haI.availability_replicas).forEach(function (r) { ha.push({ 'Server': hn, 'Instanz': i.instance_name, 'Typ': 'AG-Replikat', 'Name': r.ag_name, 'Detail': r.replica_server_name, 'Info': r.role_desc + ' / ' + r.availability_mode_desc + ' / ' + r.failover_mode_desc + ' / Secondary: ' + r.secondary_role_allow_connections_desc }); });
      asList(haI.listeners).forEach(function (r) { ha.push({ 'Server': hn, 'Instanz': i.instance_name, 'Typ': 'AG-Listener', 'Name': r.ag_name, 'Detail': r.dns_name, 'Info': 'Port ' + r.port }); });
      asList(haI.availability_databases).forEach(function (r) { ha.push({ 'Server': hn, 'Instanz': i.instance_name, 'Typ': 'AG-Datenbank', 'Name': r.ag_name, 'Detail': r.database_name, 'Info': null }); });
      asList(haI.cluster_nodes).forEach(function (r) { ha.push({ 'Server': hn, 'Instanz': i.instance_name, 'Typ': 'Cluster-Knoten', 'Name': r.node_name, 'Detail': r.status_description, 'Info': 'Aktueller Besitzer: ' + r.is_current_owner }); });
      asList(haI.log_shipping_primary).forEach(function (r) { ha.push({ 'Server': hn, 'Instanz': i.instance_name, 'Typ': 'Log Shipping (Primary)', 'Name': r.primary_database, 'Detail': null, 'Info': null }); });
      asList(haI.log_shipping_secondary).forEach(function (r) { ha.push({ 'Server': hn, 'Instanz': i.instance_name, 'Typ': 'Log Shipping (Secondary)', 'Name': r.secondary_database, 'Detail': null, 'Info': null }); });
      asList(haI.mirroring).forEach(function (r) { ha.push({ 'Server': hn, 'Instanz': i.instance_name, 'Typ': 'Database Mirroring', 'Name': r.database_name, 'Detail': r.mirroring_partner_name, 'Info': r.mirroring_role_desc + ' / ' + r.mirroring_state_desc }); });
      asList(comp.credentials).forEach(function (r) { cp.push({ 'Server': hn, 'Instanz': i.instance_name, 'Typ': 'Credential', 'Name': r.name, 'Detail': r.credential_identity, 'Konto': null }); });
      asList(comp.proxies).forEach(function (r) { cp.push({ 'Server': hn, 'Instanz': i.instance_name, 'Typ': 'Agent-Proxy', 'Name': r.name, 'Detail': r.credential_identity, 'Konto': null }); });
      asList(comp.certificates).forEach(function (r) { cp.push({ 'Server': hn, 'Instanz': i.instance_name, 'Typ': 'Zertifikat (master)', 'Name': r.name, 'Detail': 'gueltig bis ' + r.expiry_date, 'Konto': r.subject }); });
      asList(comp.tde_databases).forEach(function (r) { cp.push({ 'Server': hn, 'Instanz': i.instance_name, 'Typ': 'TDE', 'Name': r.database, 'Detail': r.algorithm + ' ' + r.key_length + ' / State ' + r.encryption_state, 'Konto': null }); });
      asList(i.endpoints).forEach(function (r) { cp.push({ 'Server': hn, 'Instanz': i.instance_name, 'Typ': 'Endpoint', 'Name': r.name, 'Detail': r.type_desc + ' / ' + r.state_desc, 'Konto': r.port ? 'Port ' + r.port : null }); });
    });
  });

  /* summary per parent group */
  var sm = [], groups = {}, total = sv.length;
  sv.forEach(function (r) { (groups[r.Obergruppe] = groups[r.Obergruppe] || []).push(r); });
  Object.keys(groups).sort(function (a, b) { return a.localeCompare(b, 'de'); }).forEach(function (gn) {
    var mySrv = groups[gn], names = {}; mySrv.forEach(function (r) { names[r.Server] = 1; });
    var myI = ins.filter(function (r) { return names[r.Server]; }), myD = db.filter(function (r) { return names[r.Server] && r.Datenbank !== 'tempdb'; }), myK = dk.filter(function (r) { return names[r.Server]; });
    sm.push({
      'Obergruppe': gn, 'Server': mySrv.length, 'Anteil Server %': total ? rnd(100 * mySrv.length / total, 1) : null, 'Instanzen': myI.length, 'Datenbanken (ohne tempdb)': myD.length,
      'Kerne gesamt': sum(mySrv, 'Kerne'), 'Logische CPUs': sum(mySrv, 'Logische CPUs'), 'RAM GB': Math.round(sum(mySrv, 'RAM GB')),
      'Platten GB (Kapazitaet)': Math.round(sum(myK, 'Groesse GB')), 'Platten GB (belegt)': Math.round(sum(myK, 'Belegt GB')),
      'DB-Daten GB': rnd(sum(myD, 'Daten GB'), 1), 'DB-Daten belegt GB': rnd(sum(myD, 'Daten belegt GB'), 1), 'Wachstum GB/Monat': rnd(sum(myD, 'Wachstum MB/Monat') / 1024, 1),
      'Virtuelle Server': mySrv.filter(function (r) { return r.Virtuell === 'ja'; }).length, 'Server ohne Anwendung': mySrv.filter(function (r) { return r.Anwendung === NZ; }).length
    });
  });
  if (sm.length > 1) {
    var tot = { 'Obergruppe': 'GESAMT', 'Server': total, 'Anteil Server %': 100 };
    ['Instanzen', 'Datenbanken (ohne tempdb)', 'Kerne gesamt', 'Logische CPUs', 'RAM GB', 'Platten GB (Kapazitaet)', 'Platten GB (belegt)', 'DB-Daten GB', 'DB-Daten belegt GB', 'Wachstum GB/Monat', 'Virtuelle Server', 'Server ohne Anwendung'].forEach(function (k) { tot[k] = rnd(sum(sm, k), 1); });
    sm.push(tot);
  }

  var sheets = { 'Zusammenfassung': sm, 'Server': sv, 'Platten': dk, 'Datentraeger': hw, 'SQL-Instanzen': ins, 'Datenbanken': db, 'Dateien': fl, 'Abhaengigkeiten': dep, 'HA-DR': ha, 'Komponenten': cp };
  if (anyJobs) sheets['Agent-Jobs'] = jb;

  /* security */
  var sec = { 'Sec-Zusammenfassung': [], 'Logins': [], 'Server-Rechte': [], 'DB-User': [], 'DB-Rollen': [], 'Rollenmitglieder': [], 'DB-Berechtigungen': [] };
  if (S.secShow) {
    scans.forEach(function (s) {
      var hn = s.host.computer_name, app = mapVal(s, 'Anwendung', 'application') || NZ, grp = mapVal(s, 'Obergruppe', 'parent_group') || NZ;
      asList(s.instances).forEach(function (i) {
        if (!isT(i.connected)) return;
        if ((i.logins === null || i.logins === undefined) && g(s, 'options', 'skip_security')) { R('HINWEIS', hn, 'Scan wurde mit -SkipSecurity erstellt, keine Security-Daten.'); return; }
        var excl = {}, kept = 0, lg = [], nUserStart = sec['DB-User'].length;
        asList(i.logins).forEach(function (l) {
          if (!S.secSys && (isT(l.is_system) || isT(l.is_sysadmin))) { excl[l.name] = 1; return; }
          kept++; lg.push(l);
          sec['Logins'].push({ 'Server': hn, 'Anwendung': app, 'Obergruppe': grp, 'Instanz': i.instance_name, 'Login': l.name, 'Typ': l.type, 'Deaktiviert': B(l.disabled), 'Default-DB': l.default_database,
            'Server-Rollen': l.server_roles, 'sysadmin': B(l.is_sysadmin), 'Policy geprueft': B(l.policy_checked), 'Ablauf geprueft': B(l.expiration_checked), 'Erstellt': l.created, 'Geaendert': l.modified });
        });
        asList(i.server_permissions).forEach(function (p) { if (!excl[p.grantee]) sec['Server-Rechte'].push({ 'Server': hn, 'Instanz': i.instance_name, 'Grantee': p.grantee, 'Recht': p.permission_name, 'Status': p.state_desc }); });
        var orph = 0;
        asList(i.db_users).forEach(function (u) {
          if (u.login_name && excl[u.login_name]) return;
          if (excl[u.name]) return;
          if (isT(u.orphaned)) orph++;
          sec['DB-User'].push({ 'Server': hn, 'Instanz': i.instance_name, 'Datenbank': u.database, 'DB-User': u.name, 'Typ': u.type, 'Authentifizierung': u.authentication, 'Login': u.login_name, 'Default-Schema': u.default_schema, 'Verwaist': B(u.orphaned), 'Erstellt': u.create_date });
        });
        asList(i.db_roles).forEach(function (r) { sec['DB-Rollen'].push({ 'Server': hn, 'Instanz': i.instance_name, 'Datenbank': r.database, 'Rolle': r.name, 'Typ': r.type, 'Owner': r.owner }); });
        asList(i.db_role_members).forEach(function (m) { if (excl[m.member]) return; sec['Rollenmitglieder'].push({ 'Server': hn, 'Instanz': i.instance_name, 'Datenbank': m.database, 'Rolle': m.role, 'Feste Rolle': B(m.role_is_fixed), 'Mitglied': m.member, 'Mitglied-Typ': m.member_type }); });
        asList(i.db_permissions).forEach(function (p) { if (excl[p.grantee]) return; sec['DB-Berechtigungen'].push({ 'Server': hn, 'Instanz': i.instance_name, 'Datenbank': p.database, 'Grantee': p.grantee, 'Grantee-Typ': p.grantee_type, 'Klasse': p.class, 'Recht': p.permission, 'Status': p.state, 'Objekt': p.target }); });
        function cnt(t) { return lg.filter(function (l) { return l.type === t; }).length; }
        sec['Sec-Zusammenfassung'].push({ 'Server': hn, 'Obergruppe': grp, 'Instanz': i.instance_name, 'Logins (gefiltert)': kept, 'Windows-Logins': cnt('WINDOWS_LOGIN'), 'Windows-Gruppen (AD)': cnt('WINDOWS_GROUP'),
          'SQL-Logins': cnt('SQL_LOGIN'), 'Zertifikat/Key-Logins': cnt('CERTIFICATE_MAPPED_LOGIN') + cnt('ASYMMETRIC_KEY_MAPPED_LOGIN'), 'Ausgefilterte (System/sysadmin)': Object.keys(excl).length,
          'DB-User': sec['DB-User'].length - nUserStart, 'Verwaiste DB-User': orph, 'Eigene DB-Rollen': asList(i.db_roles).length });
      });
    });
  }

  var model = { sheets: sheets, sec: sec, report: rep, anonKey: [] };
  if (S.anon) anonymizeModel(model);
  return model;
}

/* ---------- anonymize ---------- */
function anonInfo(scans) {
  var map = {}, key = [], n = 0;
  scans.forEach(function (s) {
    n++;
    var id = 'SRV' + ('00' + n).slice(-3);
    map[up(s.host.computer_name)] = id; key.push({ Original: s.host.computer_name, Kennung: id, Typ: 'Server' });
    asList(s.instances).forEach(function (i) {
      var nm = i.instance_name;
      if (nm && nm !== 'MSSQLSERVER' && !map[up(nm)]) { map[up(nm)] = id + '-INST' + Object.keys(map).length; key.push({ Original: nm, Kennung: map[up(nm)], Typ: 'Instanz' }); }
    });
    var dom = s.host.domain;
    if (dom && up(dom) !== 'WORKGROUP' && !map[up(dom)]) { map[up(dom)] = 'DOMAIN'; key.push({ Original: dom, Kennung: 'DOMAIN', Typ: 'Domaene' }); }
  });
  var alts = Object.keys(map).sort(function (a, b) { return b.length - a.length; }).map(function (k) { return k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); });
  var rx = alts.length ? new RegExp('(?<![A-Za-z0-9_])(' + alts.join('|') + ')(?![A-Za-z0-9_])', 'gi') : null;
  return { map: map, key: key, rx: rx, text: function (s) { return rx ? s.replace(rx, function (m) { return map[m.toUpperCase()]; }) : s; } };
}
function anonymizeModel(model) {
  var ai = anonInfo(S.scans);
  model.anonKey = ai.key;
  function fixRows(rows) {
    rows.forEach(function (r) { Object.keys(r).forEach(function (k) { if (typeof r[k] === 'string' && r[k] !== '') { r[k] = (k === 'FQDN' || k === 'IPs') ? null : ai.text(r[k]); } }); });
  }
  Object.keys(model.sheets).forEach(function (k) { fixRows(model.sheets[k]); });
  Object.keys(model.sec).forEach(function (k) { fixRows(model.sec[k]); });
  model.report.forEach(function (r) { r.Server = ai.text(String(r.Server)); r.Meldung = ai.text(String(r.Meldung)); });
}
function walkStrings(o, fn) {
  if (Array.isArray(o)) return o.map(function (x) { return walkStrings(x, fn); });
  if (o && typeof o === 'object') { var out = {}; Object.keys(o).forEach(function (k) { out[k] = walkStrings(o[k], fn); }); return out; }
  return (typeof o === 'string') ? fn(o) : o;
}

/* ---------- table rendering ---------- */
function cols(rows) {
  var seen = {}, out = [];
  rows.forEach(function (r) { Object.keys(r).forEach(function (k) { if (!seen[k]) { seen[k] = 1; out.push(k); } }); });
  return out;
}
function rowsFor(tab) {
  var m = S.model;
  if (tab === 'Pruefbericht') return m.report;
  if (m.sheets[tab]) return m.sheets[tab];
  if (m.sec[tab]) return m.sec[tab];
  return [];
}
function filteredRows(tab) {
  var rows = rowsFor(tab), f = S.filter.trim().toLowerCase();
  if (f) rows = rows.filter(function (r) { return Object.keys(r).some(function (k) { var v = r[k]; return v !== null && v !== undefined && String(v).toLowerCase().indexOf(f) >= 0; }); });
  if (S.sortCol) { var c = S.sortCol, d = S.sortDir; rows = rows.slice().sort(function (a, b) { return d * cmpVal(a[c], b[c]); }); }
  return rows;
}
function tableHtml(rows, tab, limit) {
  var cs = cols(rowsFor(tab)), h = '<table><thead><tr>';
  cs.forEach(function (c) {
    var arrow = (S.sortCol === c) ? (S.sortDir > 0 ? ' ▲' : ' ▼') : '';
    var numCol = rows.length && typeof rows[0][c] === 'number';
    h += '<th data-col="' + esc(c) + '"' + (numCol ? ' class="num"' : '') + '>' + esc(c) + arrow + '</th>';
  });
  h += '</tr></thead><tbody>';
  var shown = rows.slice(0, limit);
  shown.forEach(function (r) {
    h += '<tr>';
    cs.forEach(function (c) {
      var v = r[c], cls = (typeof v === 'number') ? 'num' : '';
      if (tab === 'Pruefbericht' && c === 'Stufe') cls = 'lvl-' + v;
      h += '<td' + (cls ? ' class="' + cls + '"' : '') + ' title="' + esc(v) + '">' + esc(v) + '</td>';
    });
    h += '</tr>';
  });
  return h + '</tbody></table>';
}
function renderTable() {
  var rows = filteredRows(S.tab), total = rowsFor(S.tab).length, host = $('tblHost');
  if (!host) return;
  host.innerHTML = rows.length ? '<div class="tblwrap">' + tableHtml(rows, S.tab, S.limit) + '</div>' : '<div class="empty-hint">Keine Zeilen.</div>';
  $('cnt').textContent = rows.length + ' von ' + total + ' Zeilen' + (rows.length > S.limit ? ' (zeige ' + S.limit + ')' : '');
  var mb = $('moreBtn'); if (mb) mb.style.display = rows.length > S.limit ? '' : 'none';
  var ths = host.getElementsByTagName('th');
  Array.prototype.forEach.call(ths, function (th) {
    th.onclick = function () { var c = th.getAttribute('data-col'); if (S.sortCol === c) S.sortDir = -S.sortDir; else { S.sortCol = c; S.sortDir = 1; } renderTable(); };
  });
}

/* ---------- tabs ---------- */
function visibleTabs() {
  var t = PROVIDER_TABS.filter(function (x) { return x !== 'Agent-Jobs' || S.model.sheets['Agent-Jobs']; });
  if (S.secShow) t = t.concat(SEC_TABS);
  return t;
}
function tabLabel(t) { return t === 'Sec-Zusammenfassung' ? 'Security' : t; }
function renderTabs() {
  var h = '';
  visibleTabs().forEach(function (t) {
    var n = (t === 'Zuordnung') ? S.scans.length : rowsFor(t).length;
    var isSec = SEC_TABS.indexOf(t) >= 0;
    h += '<div class="tab' + (S.tab === t ? ' on' : '') + (isSec ? ' secTab' : '') + '" data-tab="' + esc(t) + '">' + esc(tabLabel(t)) + '<span class="n">' + n + '</span></div>';
  });
  $('tabs').innerHTML = h;
  Array.prototype.forEach.call($('tabs').children, function (el) { el.onclick = function () { S.tab = el.getAttribute('data-tab'); S.filter = ''; S.sortCol = null; S.limit = 300; renderAll(); }; });
}

/* ---------- views ---------- */
function renderSummary() {
  var m = S.model, sv = m.sheets['Server'], ins = m.sheets['SQL-Instanzen'], db = m.sheets['Datenbanken'].filter(function (r) { return r.Datenbank !== 'tempdb'; }), dk = m.sheets['Platten'];
  var lv = {}; m.report.forEach(function (r) { lv[r.Stufe] = (lv[r.Stufe] || 0) + 1; });
  function card(v, l) { return '<div class="card"><div class="v">' + esc(v) + '</div><div class="l">' + esc(l) + '</div></div>'; }
  var h = '<div class="cards">' + card(sv.length, 'Server') + card(ins.length, 'SQL-Instanzen') + card(db.length, 'Datenbanken (ohne tempdb)') + card(Math.round(sum(sv, 'Kerne')), 'Kerne') +
          card(Math.round(sum(sv, 'RAM GB')), 'RAM GB') + card(Math.round(sum(dk, 'Groesse GB')), 'Platten GB') + card(Math.round(sum(db, 'Daten GB')), 'DB-Daten GB') + '</div>';
  var open = Object.keys(lv).filter(function (k) { return k !== 'HINWEIS'; });
  if (open.length) h += '<div class="note"><b>Pruefbericht:</b> ' + open.map(function (k) { return '<span class="lvl-' + k + '">' + esc(k) + ' ' + lv[k] + '</span>'; }).join(' &nbsp;|&nbsp; ') + ' &ndash; Details im Tab Pruefbericht.</div>';
  var rows = m.sheets['Zusammenfassung'];
  h += rows.length ? '<div class="tblwrap">' + tableHtml(rows, 'Zusammenfassung', 1000) + '</div>' : '<div class="empty-hint">Noch keine Scan-Daten geladen. Dateien ablegen oder laden.</div>';
  $('app').innerHTML = h;
}
function renderMapping() {
  var f = S.mapFilter.toLowerCase(), list = S.scans.filter(function (s) { return !f || s.host.computer_name.toLowerCase().indexOf(f) >= 0; });
  var h = '<div class="note">Anwendung und Obergruppe je Server eintragen. Mehrere Anwendungen mit | trennen. Die Eintraege gelten fuer alle Auswertungen und Exporte und werden mit <b>Sammeldatei</b> bzw. <b>Provider-HTML</b> mitgespeichert oder als <b>Zuordnung CSV</b> exportiert.</div>';
  h += '<div class="tools"><input type="text" id="mapFilter" placeholder="Server filtern ..." value="' + esc(S.mapFilter) + '">' +
       '<span>Markierte:</span> <input type="text" id="bulkApp" placeholder="Anwendung" style="width:160px"> <input type="text" id="bulkGrp" placeholder="Obergruppe" style="width:160px"> <button id="bulkGo">Anwenden</button>' +
       '<button id="selAll">Alle (sichtbar) markieren</button> <button id="selNone">Markierung aufheben</button></div>';
  ['Anwendung', 'Obergruppe'].forEach(function (c) {
    var vals = {}; S.scans.forEach(function (s) { var v = mapVal(s, c, c === 'Anwendung' ? 'application' : 'parent_group'); if (v) vals[v] = 1; });
    h += '<datalist id="dl-' + c + '">' + Object.keys(vals).sort().map(function (v) { return '<option value="' + esc(v) + '">'; }).join('') + '</datalist>';
  });
  h += '<div class="tblwrap"><table><thead><tr><th></th><th>Server</th><th>Instanzen</th>' + MAPCOLS.map(function (c) { return '<th>' + c + '</th>'; }).join('') + '</tr></thead><tbody>';
  list.forEach(function (s) {
    var hn = s.host.computer_name, k = up(hn);
    h += '<tr><td><input type="checkbox" class="sel" data-k="' + esc(k) + '"' + (S.sel[k] ? ' checked' : '') + '></td><td>' + esc(hn) + '</td><td class="num">' + asList(s.instances).length + '</td>';
    MAPCOLS.forEach(function (c) {
      var sk = (c === 'Anwendung') ? 'application' : (c === 'Obergruppe' ? 'parent_group' : null), v = mapVal(s, c, sk);
      var needs = (c === 'Anwendung' || c === 'Obergruppe') && !v;
      h += '<td><input type="text" class="mapin' + (needs ? ' empty' : '') + (c === 'Bemerkung' || c === 'Ansprechpartner' ? ' wide' : '') + '" data-k="' + esc(k) + '" data-c="' + c + '" value="' + esc(v) + '"' + ((c === 'Anwendung' || c === 'Obergruppe') ? ' list="dl-' + c + '"' : '') + '></td>';
    });
    h += '</tr>';
  });
  h += '</tbody></table></div>';
  if (!S.scans.length) h = '<div class="empty-hint">Noch keine Scan-Daten geladen.</div>';
  $('app').innerHTML = h;
  if (!S.scans.length) return;
  function setMap(k, c, v) { var o = S.mapping[k] || (S.mapping[k] = {}); o[c] = v; S.dirty = true; S.model = null; }
  Array.prototype.forEach.call(document.querySelectorAll('.mapin'), function (el) {
    el.oninput = function () { setMap(el.getAttribute('data-k'), el.getAttribute('data-c'), el.value); el.classList.toggle('empty', !el.value && (el.getAttribute('data-c') === 'Anwendung' || el.getAttribute('data-c') === 'Obergruppe')); };
  });
  Array.prototype.forEach.call(document.querySelectorAll('.sel'), function (el) { el.onchange = function () { S.sel[el.getAttribute('data-k')] = el.checked; }; });
  $('mapFilter').oninput = function () { S.mapFilter = this.value; var pos = this.selectionStart; renderMapping(); var n = $('mapFilter'); n.focus(); n.setSelectionRange(pos, pos); };
  $('selAll').onclick = function () { list.forEach(function (s) { S.sel[up(s.host.computer_name)] = true; }); renderMapping(); };
  $('selNone').onclick = function () { S.sel = {}; renderMapping(); };
  $('bulkGo').onclick = function () {
    var a = $('bulkApp').value, gr = $('bulkGrp').value, n = 0;
    Object.keys(S.sel).forEach(function (k) { if (!S.sel[k]) return; if (a) setMap(k, 'Anwendung', a); if (gr) setMap(k, 'Obergruppe', gr); n++; });
    if (n) renderMapping();
  };
}
function renderTablePage() {
  var h = '<div class="tools"><input type="text" id="flt" placeholder="Filter (alle Spalten) ..." value="' + esc(S.filter) + '"><span class="cnt" id="cnt"></span><button id="moreBtn" class="more" style="display:none">Alle anzeigen</button></div><div id="tblHost"></div>';
  $('app').innerHTML = h;
  $('flt').oninput = function () { S.filter = this.value; S.limit = 300; renderTable(); };
  $('moreBtn').onclick = function () { S.limit = 1e9; renderTable(); };
  renderTable();
}

function ensureModel() { if (!S.model) S.model = build(); }
function renderAll() {
  ensureModel();
  var hasSec = S.scans.some(hasSecurity);
  $('optSec').disabled = !hasSec; $('optSysWrap').style.display = S.secShow ? '' : 'none';
  $('bXlsxSec').disabled = !(S.secShow && hasSec); $('bKey').disabled = !S.anon;
  if (visibleTabs().indexOf(S.tab) < 0) S.tab = 'Zusammenfassung';
  var ni = 0; S.scans.forEach(function (s) { ni += asList(s.instances).length; });
  var times = S.scans.map(function (s) { return s.scan_started; }).sort();
  $('subline').textContent = S.scans.length + ' Server, ' + ni + ' Instanzen' + (times.length ? ', Scans vom ' + String(times[0]).slice(0, 10) + (times[times.length - 1].slice(0, 10) !== times[0].slice(0, 10) ? ' bis ' + String(times[times.length - 1]).slice(0, 10) : '') : '') +
    (S.anon ? ' – anonymisiert' : '');
  renderTabs();
  if (S.tab === 'Zusammenfassung') renderSummary();
  else if (S.tab === 'Zuordnung') renderMapping();
  else renderTablePage();
}

/* ---------- export ---------- */
function download(name, mime, data) {
  var blob = new Blob([data], { type: mime }), a = document.createElement('a');
  a.href = URL.createObjectURL(blob); a.download = name; document.body.appendChild(a); a.click();
  setTimeout(function () { document.body.removeChild(a); URL.revokeObjectURL(a.href); }, 500);
}
function csvOf(rows) {
  var cs = cols(rows);
  function q(v) { if (v === null || v === undefined) return ''; var s = String(v); return /[;"\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; }
  var out = [cs.map(q).join(';')];
  rows.forEach(function (r) { out.push(cs.map(function (c) { return q(r[c]); }).join(';')); });
  return '﻿' + out.join('\r\n');
}
var CRC = (function () { var t = [], c, n, k; for (n = 0; n < 256; n++) { c = n; for (k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1); t[n] = c >>> 0; } return t; })();
function crc32(b) { var c = 0xFFFFFFFF; for (var i = 0; i < b.length; i++) c = CRC[(c ^ b[i]) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; }
function zipStore(files) {
  var enc = new TextEncoder(), d = new Date(), dt = ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate(), tm = (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1);
  var chunks = [], central = [], off = 0;
  files.forEach(function (f) {
    var nb = enc.encode(f.name), data = enc.encode(f.text), crc = crc32(data), lh = new DataView(new ArrayBuffer(30));
    lh.setUint32(0, 0x04034b50, true); lh.setUint16(4, 20, true); lh.setUint16(6, 0x0800, true); lh.setUint16(8, 0, true); lh.setUint16(10, tm, true); lh.setUint16(12, dt, true);
    lh.setUint32(14, crc, true); lh.setUint32(18, data.length, true); lh.setUint32(22, data.length, true); lh.setUint16(26, nb.length, true); lh.setUint16(28, 0, true);
    chunks.push(new Uint8Array(lh.buffer), nb, data);
    var ch = new DataView(new ArrayBuffer(46));
    ch.setUint32(0, 0x02014b50, true); ch.setUint16(4, 20, true); ch.setUint16(6, 20, true); ch.setUint16(8, 0x0800, true); ch.setUint16(10, 0, true); ch.setUint16(12, tm, true); ch.setUint16(14, dt, true);
    ch.setUint32(16, crc, true); ch.setUint32(20, data.length, true); ch.setUint32(24, data.length, true); ch.setUint16(28, nb.length, true); ch.setUint32(42, off, true);
    central.push(new Uint8Array(ch.buffer), nb);
    off += 30 + nb.length + data.length;
  });
  var csize = 0; central.forEach(function (c) { csize += c.length; });
  var eo = new DataView(new ArrayBuffer(22));
  eo.setUint32(0, 0x06054b50, true); eo.setUint16(8, files.length, true); eo.setUint16(10, files.length, true); eo.setUint32(12, csize, true); eo.setUint32(16, off, true);
  return new Blob(chunks.concat(central, [new Uint8Array(eo.buffer)]), { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
}
function xe(s) { return String(s).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
function colName(i) { var s = ''; i++; while (i > 0) { var m = (i - 1) % 26; s = String.fromCharCode(65 + m) + s; i = Math.floor((i - 1) / 26); } return s; }
function xlsxBlob(sheets) {
  var names = [], used = {}, files = [];
  Object.keys(sheets).forEach(function (k) {
    var n = k.replace(/[\[\]:*?\/\\]/g, '_').slice(0, 31), base = n, c = 1;
    while (used[n.toLowerCase()]) { n = base.slice(0, 28) + '_' + (++c); }
    used[n.toLowerCase()] = 1; names.push(n);
  });
  var ct = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>';
  names.forEach(function (n, i) { ct += '<Override PartName="/xl/worksheets/sheet' + (i + 1) + '.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'; });
  files.push({ name: '[Content_Types].xml', text: ct + '</Types>' });
  files.push({ name: '_rels/.rels', text: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>' });
  var wb = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>';
  var rel = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">';
  names.forEach(function (n, i) { wb += '<sheet name="' + xe(n) + '" sheetId="' + (i + 1) + '" r:id="rId' + (i + 1) + '"/>'; rel += '<Relationship Id="rId' + (i + 1) + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet' + (i + 1) + '.xml"/>'; });
  rel += '<Relationship Id="rId' + (names.length + 1) + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>';
  files.push({ name: 'xl/workbook.xml', text: wb + '</sheets></workbook>' });
  files.push({ name: 'xl/_rels/workbook.xml.rels', text: rel });
  files.push({ name: 'xl/styles.xml', text: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="10"/><name val="Calibri"/></font><font><b/><sz val="10"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F4E79"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf></cellXfs></styleSheet>' });
  Object.keys(sheets).forEach(function (k, idx) {
    var rows = sheets[k], cs = cols(rows);
    if (!cs.length) cs = ['(keine Daten)'];
    var x = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols>';
    cs.forEach(function (c, i) { var w = Math.min(Math.max(String(c).length + 2, 8), 60); x += '<col min="' + (i + 1) + '" max="' + (i + 1) + '" width="' + w + '" customWidth="1"/>'; });
    x += '</cols><sheetData><row r="1">';
    cs.forEach(function (c, i) { x += '<c r="' + colName(i) + '1" s="1" t="inlineStr"><is><t xml:space="preserve">' + xe(c) + '</t></is></c>'; });
    x += '</row>';
    rows.forEach(function (r, ri) {
      var rn = ri + 2; x += '<row r="' + rn + '">';
      cs.forEach(function (c, i) {
        var v = r[c];
        if (v === null || v === undefined || v === '') return;
        var ref = colName(i) + rn;
        if (typeof v === 'number' && isFinite(v)) x += '<c r="' + ref + '"><v>' + v + '</v></c>';
        else x += '<c r="' + ref + '" t="inlineStr"><is><t xml:space="preserve">' + xe(String(v).slice(0, 32000)) + '</t></is></c>';
      });
      x += '</row>';
    });
    x += '</sheetData><autoFilter ref="A1:' + colName(cs.length - 1) + (rows.length + 1) + '"/></worksheet>';
    files.push({ name: 'xl/worksheets/sheet' + (idx + 1) + '.xml', text: x });
  });
  return zipStore(files);
}
function stripSecurity(scans) {
  return scans.map(function (s) {
    var c = JSON.parse(JSON.stringify(s));
    asList(c.instances).forEach(function (i) { SEC_KEYS.forEach(function (k) { delete i[k]; }); });
    c.options = c.options || {}; c.options.security_removed = true; c.scanned_by = null;
    return c;
  });
}
function htmlExport(scans, mapObj, name) {
  var clone = document.documentElement.cloneNode(true);
  clone.querySelector('#app').innerHTML = ''; clone.querySelector('#tabs').innerHTML = ''; clone.querySelector('#subline').textContent = '';
  clone.querySelector('#scan-data').textContent = safeJson(scans);
  clone.querySelector('#mapping-data').textContent = safeJson(mapObj);
  download(name, 'text/html;charset=utf-8', '<!DOCTYPE html>\n' + clone.outerHTML);
}
function currentMapObj() {
  var o = {};
  S.scans.forEach(function (s) {
    var k = up(s.host.computer_name), r = {}, any = false;
    MAPCOLS.forEach(function (c) { var v = mapVal(s, c, c === 'Anwendung' ? 'application' : (c === 'Obergruppe' ? 'parent_group' : null)); if (v) { r[c] = v; any = true; } });
    if (any) o[s.host.computer_name] = r;
  });
  return o;
}
function mappingRows() {
  return S.scans.map(function (s) {
    var r = { 'Server': s.host.computer_name };
    MAPCOLS.forEach(function (c) { r[c] = mapVal(s, c, c === 'Anwendung' ? 'application' : (c === 'Obergruppe' ? 'parent_group' : null)); });
    return r;
  });
}
function exportProviderHtml() {
  var scans = stripSecurity(S.scans), mapObj = currentMapObj();
  if (S.anon) {
    var ai = anonInfo(S.scans);
    scans = scans.map(function (s) { s.host.fqdn = null; s.host.ip_addresses = null; return walkStrings(s, function (x) { return ai.text(x); }); });
    var m2 = {}; Object.keys(mapObj).forEach(function (k) { m2[ai.map[up(k)] || k] = mapObj[k]; }); mapObj = m2;
    scans.forEach(function (s) { s.options.anonymized = true; });
  }
  htmlExport(scans, mapObj, 'ProviderInventory_Provider_' + stamp() + '.html');
}
function guardExport(fn) {
  return function () {
    ensureModel();
    try { fn(); } catch (e) { alert('Export fehlgeschlagen: ' + e.message); }
  };
}

/* ---------- wire up ---------- */
function init() {
  try { ingestScans(asList(JSON.parse($('scan-data').textContent || '[]')), 'eingebettet'); } catch (e) { S.notes.push({ Stufe: 'FEHLER', Server: 'eingebettet', Meldung: 'Eingebettete Daten nicht lesbar: ' + e.message }); }
  try { ingestMapping(JSON.parse($('mapping-data').textContent || '{}'), false); } catch (e) { /* leere Zuordnung */ }
  S.notes = S.notes.filter(function (n) { return n.Meldung.indexOf('Mehrere Scans') !== 0; });
  $('files').onchange = function () { loadFiles(this.files); this.value = ''; };
  var drop = $('drop');
  ['dragenter', 'dragover'].forEach(function (ev) { document.addEventListener(ev, function (e) { e.preventDefault(); drop.classList.add('over'); }); });
  ['dragleave', 'drop'].forEach(function (ev) { document.addEventListener(ev, function (e) { e.preventDefault(); drop.classList.remove('over'); }); });
  document.addEventListener('drop', function (e) { if (e.dataTransfer && e.dataTransfer.files.length) loadFiles(e.dataTransfer.files); });
  $('optAnon').onchange = function () { S.anon = this.checked; S.model = null; renderAll(); };
  $('optSec').onchange = function () { S.secShow = this.checked; S.model = null; renderAll(); };
  $('optSys').onchange = function () { S.secSys = this.checked; S.model = null; renderAll(); };
  $('bCsv').onclick = guardExport(function () { var t = S.tab === 'Zuordnung' ? null : S.tab; var rows = t ? filteredRows(t) : mappingRows(); download((t || 'Zuordnung') + '_' + stamp() + '.csv', 'text/csv;charset=utf-8', csvOf(rows)); });
  $('bXlsx').onclick = guardExport(function () { var o = {}; Object.keys(S.model.sheets).forEach(function (k) { o[k] = S.model.sheets[k]; }); o['Pruefbericht'] = S.model.report; download('Provider_Inventory_' + stamp() + '.xlsx', 'application/octet-stream', xlsxBlob(o)); });
  $('bXlsxSec').onclick = guardExport(function () { var o = {}; Object.keys(S.model.sec).forEach(function (k) { o[k === 'Sec-Zusammenfassung' ? 'Zusammenfassung' : k] = S.model.sec[k]; }); download('Security_Inventory_' + stamp() + '.xlsx', 'application/octet-stream', xlsxBlob(o)); });
  $('bHtmlProv').onclick = guardExport(function () { exportProviderHtml(); });
  $('bHtmlFull').onclick = guardExport(function () { htmlExport(S.scans, currentMapObj(), 'ProviderInventory_Sammeldatei_' + stamp() + '.html'); S.dirty = false; });
  $('bMap').onclick = guardExport(function () { download('Zuordnung_' + stamp() + '.csv', 'text/csv;charset=utf-8', csvOf(mappingRows())); S.dirty = false; });
  $('bRep').onclick = guardExport(function () {
    var by = {}, out = ['Pruefbericht Provider-Inventar, ' + new Date().toISOString().slice(0, 16).replace('T', ' '), 'Scans: ' + S.scans.length + ' Server', ''];
    S.model.report.forEach(function (r) { (by[r.Stufe] = by[r.Stufe] || []).push(r); });
    Object.keys(by).sort().forEach(function (k) { out.push('== ' + k + ' (' + by[k].length + ') =='); by[k].forEach(function (r) { out.push('  ' + r.Server + ': ' + r.Meldung); }); out.push(''); });
    if (!S.model.report.length) out.push('Keine Auffaelligkeiten.');
    download('Pruefbericht_' + stamp() + '.txt', 'text/plain;charset=utf-8', '﻿' + out.join('\r\n'));
  });
  $('bKey').onclick = guardExport(function () { download('Anonymisierung_Schluessel_' + stamp() + '.csv', 'text/csv;charset=utf-8', csvOf(S.model.anonKey)); });
  window.addEventListener('beforeunload', function (e) { if (S.dirty) { e.preventDefault(); e.returnValue = ''; } });
  renderAll();
}
init();
})();
</script>
</body>
</html>

'@
}

function ConvertTo-sqmProviderInventoryHtml
{
	[CmdletBinding()]
	[OutputType([string])]
	param (
		# Ein oder mehrere Scans als fertiges JSON (je Element ein Objekt)
		[Parameter(Mandatory = $true)]
		[string[]]$ScanJson,
		[Parameter(Mandatory = $false)]
		[string]$Title = 'Provider-Inventar'
	)

	$encTitle = $Title.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
	$ref = (Get-sqmReportReference).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
	$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
	# '<' als \u003c: gueltig in JSON-Strings, verhindert </script> und <!-- im Datenblock
	$data = '[' + (($ScanJson | ForEach-Object { $_.Trim() }) -join ',') + ']'
	$data = $data.Replace('<', '\u003c')

	$t = Get-sqmProviderInventoryViewerTemplate
	$t = $t.Replace('@@TITLE@@', $encTitle).Replace('@@REF@@', $ref).Replace('@@STAMP@@', $stamp).Replace('@@MAPDATA@@', '{}')
	return $t.Replace('@@SCANDATA@@', $data)
}
