"""Build a private, offline English audit report from filesystem metadata."""
import re
import argparse
import base64
import csv
from datetime import datetime
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
for name in ('audit', 'hardware', 'config', 'chartjs', 'output'):
    parser.add_argument('--' + name, type=Path, required=True)
args = parser.parse_args()
rows = list(csv.DictReader((args.audit / 'folder-summary.csv').open(encoding='utf-8-sig')))
for row in rows:
    for key in row:
        if key not in ('Path', 'LatestUtc'):
            row[key] = int(row[key])
hardware = json.loads(args.hardware.read_text(encoding='utf-8-sig'))
current = json.loads((args.audit / 'disk-benchmark.json').read_text(encoding='utf-8-sig'))
# An earlier measurement to compare with is optional.
baseline_path = args.audit / 'disk-benchmark-usb2.json'
baseline = json.loads(baseline_path.read_text(encoding='utf-8-sig')) if baseline_path.exists() else None
usb = json.loads((args.audit / 'usb-speed.json').read_text(encoding='utf-8-sig'))
config = json.loads(args.config.read_text(encoding='utf-8-sig'))
bundle = args.chartjs.read_bytes()
expected = 'jb8JQMbMoBUzgWatfe6COACi2ljcDdZQ2OxczGA3bGNeWe+6DChMTBJemed7ZnvJ'
if base64.b64encode(hashlib.sha384(bundle).digest()).decode() != expected:
    raise ValueError('Chart.js checksum mismatch')
data = {
    'rows': rows, 'cpu': hardware['CPU']['Name'],
    'ram': round(hardware['System']['TotalPhysicalMemory'] / 2**30),
    'disk': current['Disk'], 'benchmark': current['Benchmark'],
    'old': baseline['Benchmark'] if baseline else None, 'usb': usb,
    'choices': config['Choices'], 'notes': config.get('ReportNotes', []),
    # .NET writes up to 7 fractional digits; Python before 3.11 accepts at most 6.
    'date': datetime.fromisoformat(re.sub(r'(\.\d{6})\d+', r'\1', current['Utc']).replace('Z', '+00:00')).astimezone().strftime('%Y-%m-%d'),
}

template = r'''<!doctype html>
<html lang="en" dir="ltr">
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Backup Center — Drive Report</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f4f5f8;color:#15263b;font:16px/1.65 "Segoe UI",Arial,sans-serif}
main{max-width:1240px;padding:40px 24px 80px;margin:auto}h1{font-size:36px;margin:0}h2{font-size:22px;margin:0 0 16px}p{margin:8px 0 16px}
.eyebrow{color:#167a70;font-weight:700;letter-spacing:1px}.muted{color:#536479}.kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:28px 0}
.card,section{background:white;border:1px solid #dce2e8;border-radius:12px;padding:23px;margin-bottom:20px}.kpis .card{margin:0}.value{font-size:30px;font-weight:700}
.grid{display:grid;grid-template-columns:1.15fr 1fr;gap:20px}.chart{height:330px}table{width:100%;border-collapse:collapse;font-size:14px}td,th{padding:11px 8px;text-align:left;border-bottom:1px solid #e7ebef;vertical-align:top}th{color:#536479;cursor:pointer}
code,.path{direction:ltr;unicode-bidi:embed;display:inline-block;font-family:Consolas,monospace}.path{word-break:break-word}input,select,button{font:inherit;padding:7px 10px;border:1px solid #aebac8;border-radius:6px;background:white}button{cursor:pointer}
.toolbar{display:flex;gap:12px;flex-wrap:wrap;margin:12px 0}.badge{font-size:12px;font-weight:600;padding:3px 8px;border-radius:20px;white-space:nowrap}.high{color:#126651;background:#e0f4eb}.review{color:#855200;background:#fff0d1}.low{color:#506174;background:#edf1f5}
.callout{border-left:4px solid #167a70;background:#edf8f5;padding:16px;border-radius:6px}.scroll{overflow:auto}.foot{font-size:13px;color:#536479}a{color:#176b97}
@media(max-width:800px){.grid{grid-template-columns:1fr}.kpis{grid-template-columns:repeat(2,1fr)}h1{font-size:29px}main{padding:25px 14px}.card,section{padding:16px}}
@media print{button,input,select{display:none}.grid{display:block}.card,section{break-inside:avoid}body{background:white}}
</style>
<main>
<div class="eyebrow">DEV DRIVE · <span id="date"></span> · LOCAL AUDIT</div>
<h1>What to preserve. What can be rebuilt.</h1>
<p class="muted">An inventory of accessible filesystem metadata, with hardware and transfer measurements. Recommendations are judgments based on location and file type; a folder name alone does not prove that its contents are disposable.</p>
<div class="kpis">
<div class="card">Scanned file size<div class="value" id="total"></div></div>
<div class="card">Accessible files<div class="value" id="files"></div></div>
<div class="card">Identified caches and dependencies<div class="value" id="caches"></div></div>
<div class="card">Measured write-speed improvement<div class="value" id="gain"></div></div>
</div>
<div class="grid">
<section><h2>Where the space goes</h2><div class="chart"><canvas id="chart" aria-label="Top-level folder sizes" role="img"></canvas></div><p class="foot">Logical file size in GiB. Allocated disk usage differs because of metadata, sparse files and links.</p></section>
<section><h2>Connection and measured performance</h2><div id="hardware"></div><table><thead><tr><th>Measurement</th><th>Write MB/s</th><th>Read MB/s</th></tr></thead><tbody id="speed"></tbody></table><p class="foot" id="benchmark-note"></p></section>
</div>
<section><h2>Recommendations for this computer</h2>
<div class="callout">Preserve Git history, uncommitted work, assets, data and configuration in encrypted versioned snapshots. Worktrees may contain unique local changes. There is no blanket exclusion of build, dist, data, .git or large files.</div>
<div id="notes"></div><p>Review temporary data, experiments and build outputs for unique exceptions. Deduplication may reduce repeated content. Source files and the existing mirror are preserved.</p></section>
<section><h2>Folder size and backup priority</h2>
<div class="toolbar"><select id="scope" aria-label="Detail level"><option value="root">Top-level folders</option><option value="all">All summarized levels</option></select><input id="search" placeholder="Search folders" aria-label="Search folders"><button id="csv">Export summary CSV</button></div>
<div class="scroll"><table><thead><tr><th data-sort="Path">Folder</th><th data-sort="Bytes">GiB</th><th data-sort="Files">Files</th><th data-sort="CacheBytes">Cache GiB</th><th>Priority and recommendation</th></tr></thead><tbody id="rows"></tbody></table></div><p id="count" class="foot"></p></section>
<section><h2>Performance profiles</h2><p>The application lets you select a profile and edit its bandwidth and memory limits. The hard limit applies to the Restic process committed memory, not the Windows file cache. Go uses a lower soft target. Quiet and Balanced use BelowNormal CPU priority.</p>
<table><thead><tr><th>Profile</th><th>Repository I/O cap</th><th>Process memory cap</th><th>CPU / file-read concurrency</th></tr></thead><tbody>
<tr><td>Quiet</td><td>15 MB/s</td><td>512 MiB</td><td>1 / 1</td></tr><tr><td>Balanced</td><td>45 MB/s</td><td>1024 MiB</td><td>2 / 2</td></tr><tr><td>Fast</td><td>Unlimited</td><td>2048 MiB</td><td>4 / 4</td></tr></tbody></table>
<p class="foot">Processed source MB/s can exceed repository write MB/s because of compression and deduplication. The bandwidth cap does not limit every source read. Zero impact on interactive work cannot be guaranteed.</p></section>
<section><h2>Coverage and limitations</h2><p id="limits"></p>
<p>File contents were not read to assign backup priority. Sizes exclude link targets, inaccessible contents and Windows-managed system folders. Do not add parent and child aggregate rows together. The inventory represents a time window, without an atomic filesystem snapshot.</p>
<p>Keep the portable recovery key outside this computer. Run full repository verification and a real restore into a new folder. Add a second independently stored copy. Repository data, passwords and private audit reports are excluded from the public source bundle.</p>
<p class="foot">References: <a href="https://restic.readthedocs.io/en/stable/040_backup.html">Restic backup and exclusions</a> · <a href="https://restic.readthedocs.io/en/stable/047_tuning_parameters.html">Performance tuning</a> · <a href="https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/usbioctl/ni-usbioctl-ioctl_usb_get_node_connection_information_ex_v2">Microsoft SuperSpeed diagnostics</a></p></section>
<p class="foot">Private local report. Do not publish this report, personal configuration or encryption keys.</p>
</main>
<script>__CHARTJS__</script><script>
const D=__DATA__, fmt=new Intl.NumberFormat('en-US'), gib=n=>(n/1073741824).toFixed(2);
const el=id=>document.getElementById(id), esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const all=D.rows.find(r=>r.Path==='(all)'), roots=D.rows.filter(r=>!r.Path.includes('\\')&&r.Path!=='(all)').sort((a,b)=>b.Bytes-a.Bytes);
el('date').textContent=D.date;el('total').textContent=gib(all.Bytes)+' GiB';el('files').textContent=fmt.format(all.Files);el('caches').textContent=gib(all.CacheBytes)+' GiB';el('gain').textContent=D.old?(D.benchmark.WriteMBps/D.old.WriteMBps).toFixed(2)+'×':'—';
el('hardware').innerHTML='<p>'+esc(D.cpu)+'<br>'+D.ram+' GiB RAM · '+esc(D.disk)+'<br>'+esc(D.usb.Speed)+'</p>';
el('speed').innerHTML=[['Baseline',D.old],['Current connection',D.benchmark]].filter(([,b])=>b).map(([name,b])=>'<tr><td>'+name+'</td><td>'+b.WriteMBps.toFixed(1)+'</td><td>'+b.ReadMBps.toFixed(1)+'</td></tr>').join('');
el('benchmark-note').textContent='Short test: '+fmt.format(D.benchmark.Bytes/1048576)+' MiB, '+(D.benchmark.BlockBytes/1048576)+' MiB blocks, unbuffered I/O and write-through writes. This is a point-in-time measurement, not a sustained-speed guarantee or a small-file transfer benchmark. Drive/controller caches may still affect it.';
el('limits').textContent=fmt.format(all.Errors)+' access or metadata errors were recorded. '+fmt.format(all.Links)+' links were not followed. '+fmt.format(all.Directories)+' directories were identified.';
new Chart(el('chart'),{type:'bar',data:{labels:roots.map(r=>r.Path),datasets:[{data:roots.map(r=>r.Bytes/1073741824),backgroundColor:'#17877c',borderRadius:4}]},options:{indexAxis:'y',maintainAspectRatio:false,animation:false,plugins:{legend:{display:false}},scales:{x:{title:{display:true,text:'GiB'}}}}});
el('notes').innerHTML=D.notes.map(n=>'<p>'+esc(n)+'</p>').join('');
D.rows.filter(r=>r.Path!=='(all)'&&r.Path.split('\\').length<3&&D.rows.some(c=>c.Path.startsWith(r.Path+'\\'))).forEach(r=>{const o=document.createElement('option');o.value=r.Path;o.textContent=r.Path;el('scope').append(o)});
function advice(r){
 const p=r.Path.toLowerCase();
 if(/(^|\\)(node_modules|\.venv|venv|__pycache__|\.pytest_cache|\.pnpm-store)(\\|$)/.test(p)||p==='packages')return ['low','Low','Dependencies or cache; rebuildable if packages and pinned versions remain available.'];
 if(p.startsWith('temp')||p==='tmp')return ['review','Review','Temporary or reinstallable software; check for unique data and configuration.'];
 if(p.includes('test-results')||p.includes('builds'))return ['review','Review','Evidence, artifacts and experiment results may be unique; preserve initially.'];
 const choice=D.choices.find(c=>r.Path===c.Path||r.Path.startsWith(c.Path+'\\'));
 return ['high','Recommended',choice?choice.Reason:'Preserve source, data, configuration, assets, history and local changes.'];
}
let sort='Bytes',desc=true,visible=[];
function render(){
 const q=el('search').value.toLowerCase(),scope=el('scope').value;
 visible=D.rows.filter(r=>r.Path!=='(all)').filter(r=>scope==='all'||scope==='root'&&!r.Path.includes('\\')||scope!=='root'&&r.Path.startsWith(scope+'\\')&&r.Path.split('\\').length===scope.split('\\').length+1).filter(r=>r.Path.toLowerCase().includes(q)).sort((a,b)=>(typeof a[sort]==='number'?a[sort]-b[sort]:a[sort].localeCompare(b[sort]))*(desc?-1:1));
 el('rows').innerHTML=visible.slice(0,200).map(r=>{const [c,n,t]=advice(r);return '<tr><td><span class="path">'+esc(r.Path)+'</span></td><td>'+gib(r.Bytes)+'</td><td>'+fmt.format(r.Files)+'</td><td>'+gib(r.CacheBytes)+'</td><td><span class="badge '+c+'">'+n+'</span> '+esc(t)+(r.Errors?' · '+r.Errors+' errors':'')+'</td></tr>'}).join('');
 el('count').textContent='Showing '+Math.min(visible.length,200)+' of '+visible.length+' summarized rows. Export CSV for all matching rows.';
}
el('search').addEventListener('input',render);el('scope').addEventListener('change',render);
document.querySelectorAll('[data-sort]').forEach(h=>h.addEventListener('click',()=>{desc=sort===h.dataset.sort?!desc:true;sort=h.dataset.sort;render()}));
el('csv').addEventListener('click',()=>{
 const fields=['Path','Bytes','Files','CacheBytes','Errors'];
 const text='\ufeff'+fields.join(',')+'\r\n'+visible.map(r=>fields.map(f=>'"'+String(r[f]).replaceAll('"','""')+'"').join(',')).join('\r\n');
 const link=document.createElement('a');link.href=URL.createObjectURL(new Blob([text],{type:'text/csv;charset=utf-8'}));link.download='devdrive-folder-summary.csv';link.click();setTimeout(()=>URL.revokeObjectURL(link.href),1000);
});render();
</script></html>'''
html = template.replace('__CHARTJS__', bundle.decode()).replace('__DATA__', json.dumps(data, ensure_ascii=False).replace('</', '<\\/'))
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(html, encoding='utf-8')
print(args.output)
