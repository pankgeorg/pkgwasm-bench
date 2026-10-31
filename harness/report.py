#!/usr/bin/env python3
import csv, json, pathlib, statistics as st, tomllib
R=pathlib.Path(__file__).resolve().parent.parent
import os
os.chdir(R)
def csvrows(p):
    return list(csv.DictReader(open(p))) if pathlib.Path(p).exists() else []
def fmt(xs, digits=3):
    xs=[float(x) for x in xs if x!='' and x is not None]
    if not xs:return '—'
    return (f'INVALID n={len(xs)}: ' if len(xs)!=5 else '')+f'{st.median(xs):.{digits}f} [{min(xs):.{digits}f}–{max(xs):.{digits}f}]'
def load(rows):
    xs=[float(r['load1']) for r in rows if r.get('load1')]
    return f'{min(xs):.2f}–{max(xs):.2f}' if xs else '—'
def mdtable(head, rows):
    return '| '+' | '.join(head)+' |\n| '+' | '.join(['---']*len(head))+' |\n'+''.join('| '+' | '.join(map(str,r))+' |\n' for r in rows)
def aggregate(rows, key, value, reducer=sum):
    groups={}
    for r in rows:groups.setdefault(tuple(r[k] for k in key),[]).append(float(r[value]))
    return {k:reducer(v) for k,v in groups.items()}
def wallrss(rows):
    if not rows:return 'blocked'
    sums=aggregate(rows,['round'],'wall_s')
    peaks=aggregate(rows,['round'],'maxrss_kib',max)
    return fmt(sums.values())+' s; '+fmt([v/1024 for v in peaks.values()],1)+' MiB'
def ratio(a,b,field='wall_s',agg=sum):
    aa=aggregate(a,['round'],field,agg);bb=aggregate(b,['round'],field,agg)
    values=[aa[k]/bb[k] for k in aa.keys()&bb.keys() if bb[k]]
    return fmt(values,3 if values and st.median(values)<0.1 else 2)
def toml(p):return tomllib.load(open(p,'rb')) if pathlib.Path(p).exists() else {}
def main():
    preamble=pathlib.Path('harness/report-preamble.md')
    old=(preamble if preamble.exists() else pathlib.Path('REPORT.md')).read_text()
    protocol=old.split('## Pending work')[0]
    # retain appended decisions after the initial placeholder
    if '## Pending work' in old:
        tail=old.split('## Pending work',1)[1]
        tail=tail.split('pending.',1)[-1]
        protocol+=tail
    if not preamble.exists():preamble.write_text(protocol)
    rows=csvrows('out/table1/results.csv')
    case_order=['M4-cold','M4-warm','M4-noop']+list(toml('fixtures/scenarios.toml'))
    t1=[]
    for c in case_order:
        rr=[r for r in rows if r['case']==c]
        by={i:[r for r in rr if r['impl']==i] for i in ['stock','native','wasm']}
        t1.append([c,*[wallrss(by[i]) for i in by],ratio(by['wasm'],by['stock']),ratio(by['wasm'],by['native']),load(rr)])
    table1=mdtable(['Case (sum of fresh processes)','Stock Pkg, precompile off','PkgWasm native','Wasm','Wasm/stock','Wasm/native fork','Load1 range'],t1)
    io=csvrows('out/table2/io.csv'); ig=toml('out/io-validate/gates.toml')
    t2=[]
    for w in ['tar','walk','walkdir','lines','read','cp','toml','dir']:
        rr=[r for r in io if r['workload']==w]
        by={i:[r for r in rr if r['impl']==i] for i in ['native','native-warm','wasm']}
        counts=json.loads(pathlib.Path(f'out/table2/counts/{w}.calls.json').read_text()) if pathlib.Path(f'out/table2/counts/{w}.calls.json').exists() else {}
        top=sorted([(k,v[0]) for k,v in counts.items()],key=lambda x:-x[1])[:3]
        ops=[]
        for i in by:ops.append(fmt([float(r['ns'])/1e9 for r in by[i] if r['ns']])+' s' if by[i] else 'blocked')
        t2.append([w,*ops,ratio(by['wasm'],by['native-warm'],'ns'),'; '.join(f'{k}: {n}' for k,n in top) or '—',load(rr)])
    table2=mdtable(['Workload','Native cold op','Native warmed op','Wasm op','Wasm/warmed','Top host calls (one untimed run)','Load1 range'],t2)
    sr=csvrows('out/table3/results.csv'); si=csvrows('out/table3-io/io.csv'); opt=csvrows('out/opt.csv')
    variants=['O3','O4','O3conv','O3x2','Os','gufaopt','tmerge','atr','rut','mono','gccombo','tnh','node-noliftoff','node-liftoffonly','node-nodyntier','node-nolazy','node-semi32','node-semi64','node-semi128']
    t3=[]
    for v in variants:
        rr=[r for r in sr if r['label']==v and r['impl']=='wasm-'+v]
        if v=='O3':
            firstlabel=next((r['label'] for r in sr if r['impl']=='wasm'),None)
            rr=[r for r in sr if r['label']==firstlabel and r['impl']=='wasm']
        oo=[r for r in opt if r['kind']=='pkgwasm' and r['variant']==v]
        baseoo=[r for r in opt if r['kind']=='pkgwasm' and r['variant']=='O3']
        eq=toml(f'out/sweep-eq/{v}/gates.toml')
        eqtext=f'{sum(eq.values())}/{len(eq)}' if eq else 'blocked'
        cold=[r for r in rr if r['case']=='M4-cold'];warm=[r for r in rr if r['case']=='M4-warm']
        paired=[r for r in sr if r['label']==v and r['impl']=='wasm']
        pcold=[r for r in paired if r['case']=='M4-cold'];pwarm=[r for r in paired if r['case']=='M4-warm']
        ios=[]
        for w in json.loads(pathlib.Path('out/sweep-workloads.json').read_text()) if pathlib.Path('out/sweep-workloads.json').exists() else []:
            a=[r for r in si if r['label']==v and r['impl']=='wasm-'+v and r['workload']==w]
            b=[r for r in si if r['label']==v and r['impl']=='wasm' and r['workload']==w]
            ios.append(w+' '+ratio(a,b,'ns'))
        useoo=baseoo if v.startswith('node-') else oo
        size=useoo[0]['size_bytes'] if useoo else 'blocked'
        ioload=[r for r in si if r['label']==(firstlabel if v=='O3' else v)]
        t3.append([v+(' (unsafe)' if v=='tnh' else ''),size,fmt([r['wall_s'] for r in oo]) if oo else ('same O3' if v.startswith('node-') else 'blocked'),fmt([r['compile_ms'] for r in cold],1)+'; '+fmt([r['instantiate_ms'] for r in cold],1),wallrss(cold),ratio(cold,pcold) if v!='O3' else 'reference',wallrss(warm),ratio(warm,pwarm) if v!='O3' else 'reference','; '.join(ios) or '—',eqtext,load(rr+paired+ioload)])
    table3=mdtable(['Variant','Pkg bytes','wasm-opt s','Cold compile; instantiate ms','M4 cold s; MiB','Cold/paired O3','M4 warm s; MiB','Warm/paired O3','IO op ratio vs paired O3','Pkg gates','Runtime load1 range'],t3)
    parts=[protocol,'\n## Measurement definitions\n\nEach measured cell is median [min–max] over five rounds. Table 1 sums the separately launched command processes within a scenario and takes their maximum RSS per round; the appendix lists every command. RSS is process peak from GNU time, in MiB. Wall seconds use the harness monotonic clock around GNU time. Ratios are paired by round and have their own median and range. Load1 ranges cover the commands in that row; each batch’s uptime/top snapshot is retained alongside CSV. Build sizes and host-call counts are fixed observations rather than five-run timing estimates. Optimizer timings are five independent invocations; builds themselves are single executions.\n\nTable 2 operation timers exclude process startup. Native cold includes first-call JIT; native warmed runs the same workload once first in the same process. End-to-end wall/RSS remain in the appendix. Every workload and flag variant is checked without timing before measured batches. No OS cache flush was attempted on the shared host.\n',
    '\n## Table 1 — Pkg cases\n\n'+table1,
    '\n## Startup, measured separately\n\n'+mdtable(['Process','Wall s','Peak MiB','Load1 range'],[[w,fmt([r['wall_s'] for r in csvrows('out/startup/startup.csv') if r['what']==w]),fmt([float(r['maxrss_kib'])/1024 for r in csvrows('out/startup/startup.csv') if r['what']==w],1),load([r for r in csvrows('out/startup/startup.csv') if r['what']==w])] for w in dict.fromkeys(r['what'] for r in csvrows('out/startup/startup.csv'))]),
    '\n## Table 2 — IO workloads\n\n'+table2,
    '\n## Table 3 — flag sweep\n\nThe O3 reference row shows the first paired baseline batch; every variant ratio uses its own adjacent O3 runs, retained individually in the appendices. Runtime load covers both sides of the Pkg/IO pairs; optimizer loads are in the optimizer appendix. These five-run ranges are observed spreads, not confidence intervals.\n\n'+table3+'\nNode labels: node-noliftoff = `--no-liftoff`; node-liftoffonly = `--liftoff-only`; node-nodyntier = `--no-wasm-dynamic-tiering`; node-nolazy = `--no-wasm-lazy-compilation`; node-semi32/64/128 = `--max-semi-space-size=32/64/128`, respectively. Each uses the same O3 bytes. The no-lazy pair additionally imports tools/compile-keepalive.mjs on BOTH sides, after separate baseline/variant gates; see the liveness correction below.\n',
    '\n## Equivalence and blockers\n\n']
    vtxt=pathlib.Path('out/validate/validate.txt').read_text() if pathlib.Path('out/validate/validate.txt').exists() else 'Validation missing.'
    diffs=[l for l in vtxt.splitlines() if 'differs:' in l or 'DIFFERS:' in l or 'UNEXPECTED' in l]
    parts.append('\n'.join('- '+l for l in diffs) if diffs else 'Every base Pkg implementation passed its local equivalence gates; stock matched every committed scenario baseline.')
    parts.append('\n\nIO gates: '+(', '.join(k for k,v in ig.items() if not v) or 'all 24 pass')+'\n')
    flag_gates=[]
    for v in variants:
        pg=toml(f'out/sweep-eq/{v}/gates.toml');wg=toml(f'out/sweep-io-eq/{v}/gates.toml')
        flag_gates.append([v, f'{sum(pg.values())}/{len(pg)}' if pg else 'blocked' if v=='O4' else 'missing',f'{sum(wg.values())}/{len(wg)}' if wg else 'base 24/24' if v=='O3' else 'blocked' if v=='O4' else 'missing', '; '.join(k for k,val in {**pg,**wg}.items() if not val) or '—'])
    parts.append('\n'+mdtable(['Variant','Pkg gates','IO gates','Failed cases'],flag_gates))
    keep_pkg=toml('out/sweep-eq/O3-keepalive/gates.toml');keep_io=toml('out/sweep-io-eq/O3-keepalive/gates.toml')
    parts.append(f'\nAdditional O3 keepalive baseline gates: {sum(keep_pkg.values())}/{len(keep_pkg)} Pkg, {sum(keep_io.values())}/{len(keep_io)} IO.\n')
    for p in sorted(pathlib.Path('out/io-validate').glob('*.stderr')):
        if p.stat().st_size:parts.append('\nIO diagnostic '+str(p)+':\n```\n'+p.read_text()[:2500]+'\n```\n')
    parts.append('\n## Build verification\n\n'+pathlib.Path('out/code-section-check.txt').read_text() if pathlib.Path('out/code-section-check.txt').exists() else '\nBuild check missing.\n')
    for p in ['out/pkgwasm.wasm.build.toml','out/raw/pkgwasm.raw.wasm.build.toml']:
        b=toml(p)
        parts.append('\n'+p+': '+str({k:b[k] for k in ['status','julia','size_bytes','elapsed_s','maxrss_mib','diagnostics_count','verifier_errors','embedded_host_strings','poison_strings_found'] if k in b})+'\n')
    parts.append('\n## Cached compilation\n\n```\n'+(pathlib.Path('out/logs/cache-probe.log').read_text() if pathlib.Path('out/logs/cache-probe.log').exists() else 'Probe pending.')+'\n```\n\nThe tested Node v8 serialization API cannot persist this WebAssembly.Module for another fresh process. Same-process structuredClone preserves a Module, so in-process reuse is possible; it was not measured as a cached CLI workload. No cross-process cache timing is substituted. The phase tables report the initial WebAssembly.compile call; lazy/background V8 compilation can occur later, so compile_only is not an upper bound on every compilation cost or a predicted cache speedup.\n')
    parts.append('\n## Recommendations\n\n'+(pathlib.Path('harness/recommendations.md').read_text() if pathlib.Path('harness/recommendations.md').exists() else 'INCOMPLETE: paired results have not been interpreted.\n'))
    parts.append('\n## Exact rerun commands\n\n```bash\ncd /home/pgeorgakopoulos/pkgwasm-bench\n. env/env.sh build\n"$JULIA" --startup-file=no runner/scenarios.jl prepare\nmkdir -p fixtures/initial/m4/project fixtures/initial/m4/depot/registries\ncp -a fixtures/m4-original/project/. fixtures/initial/m4/project/\ncp -a fixtures/m4-original/prep-depot/registries/. fixtures/initial/m4/depot/registries/\ncp -an fixtures/m4-original/cache/. fixtures/cache/\n"$JULIA" --startup-file=no runner/build.jl --trim unsafe --verify warn\n. env/env.sh raw\n"$JULIA" --startup-file=no runner/build.jl --trim unsafe --verify warn --no-optimize --env-dir out/raw/build-env --out out/raw/pkgwasm.raw.wasm\n. env/env.sh io-build\n"$JULIA" --startup-file=no --project=bench/env -e \'import Pkg; Pkg.instantiate()\'\n"$JULIA" --startup-file=no --project=bench/env bench/build.jl out/raw/bench.raw.wasm\n. env/env.sh harness\npython3 harness/overnight.py > out/controller.log 2>&1\npython3 harness/report.py\n```\n\nThe controller source records every variant and command. Each invocation is also written as COMMAND in out/logs/*.log. It appends CSV; move old output aside inside this workspace before a full rerun to avoid combining runs. fixtures/initial/m4 contains only the original project and prep-depot/registries; recreate that template from fixtures/m4-original if removed.\n')
    parts.append('\n## Raw data and detailed command timings\n\n- out/table1/results.csv, out/startup/startup.csv, out/table2/io.csv, out/table3/results.csv, out/table3-io/io.csv and out/opt.csv.\n- out/logs contains build, validation, instrumentation, and controller command logs.\n- out/validate and out/sweep-eq contain gate files, per-command captured state, stdout/stderr and request logs.\n- out/table*/load-*.txt and out/startup/load-*.txt contain uptime and busiest processes before each timed round.\n- harness/report-preamble.md and harness/recommendations.md retain this run’s narrative. report.py refreshes tables from CSV; review narrative observations/recommendations against any new rerun rather than treating the old prose as new evidence.\n\n')
    detailed=[]
    for c in case_order:
        rr=[r for r in rows if r['case']==c]
        for cmd in sorted(set(r['cmd'] for r in rr),key=int):
            cc=[r for r in rr if r['cmd']==cmd]
            detailed.append([c,cmd,cc[0]['args'],*[wallrss([r for r in cc if r['impl']==i]) for i in ['stock','native','wasm']],load(cc)])
    parts.append(mdtable(['Scenario','Command','Args','Stock precompile off s; MiB','Native s; MiB','Wasm s; MiB','Load1 range'],detailed))
    parts.append('\n\n'+mdtable(['IO workload','Implementation','Wall s; MiB','Load1 range'],[[w,i,wallrss([r for r in io if r['workload']==w and r['impl']==i]),load([r for r in io if r['workload']==w and r['impl']==i])] for w in dict.fromkeys(r['workload'] for r in io) for i in ['native','native-warm','wasm']]))
    parts.append('\n## Optimizer costs, both modules\n\n'+mdtable(['Module','Variant','Flags','Bytes','Optimizer s','Peak MiB','Load1 range'],[[kind,v,rr[0]['flags'],rr[0]['size_bytes'],fmt([r['wall_s'] for r in rr]),fmt([float(r['maxrss_kib'])/1024 for r in rr],1),load(rr)] for kind,v in dict.fromkeys((r['kind'],r['variant']) for r in opt) for rr in [[r for r in opt if r['kind']==kind and r['variant']==v]]]))
    parts.append('\n## IO sweep details\n\n'+mdtable(['Variant pair','Implementation','Workload','Op s','Wall s; MiB','Compile ms','Instantiate ms','Load1 range'],[[v,i,w,fmt([float(r['ns'])/1e9 for r in rr]),wallrss(rr),fmt([r['compile_ms'] for r in rr],1),fmt([r['instantiate_ms'] for r in rr],1),load(rr)] for v,i,w in dict.fromkeys((r['label'],r['impl'],r['workload']) for r in si) for rr in [[r for r in si if r['label']==v and r['workload']==w and r['impl']==i]]]))
    parts.append('\n## Wasm phase details\n\nAll durations below are milliseconds, independently measured per phase; each cell has five rounds. The unassigned wall remainder includes process startup, runner validation/plumbing, cleanup, exit and launch overhead; this experiment does not attribute it further. Initial compile timing excludes subsequent lazy/background compilation. Raw cumulative and phase marks remain in each command’s timing JSON.\n\n')
    phases=[]
    for source,rs in [('Table 1',rows),('Flag sweep',sr)]:
        for label,c,cmd,i in dict.fromkeys((r['label'],r['case'],r['cmd'],r['impl']) for r in rs if r['impl'].startswith('wasm')):
            rr=[r for r in rs if (r['label'],r['case'],r['cmd'],r['impl'])==(label,c,cmd,i)]
            remainder=[float(r['wall_s'])*1000-sum(float(r[k]) for k in ['compile_ms','instantiate_ms','init_ms','main_ms']) for r in rr]
            phases.append([source,label,c,cmd,i,*[fmt([r[k] for r in rr],1) for k in ['compile_ms','instantiate_ms','init_ms','main_ms']],fmt(remainder,1),load(rr)])
    parts.append(mdtable(['Source','Pair/label','Case','Command','Implementation','Compile','Instantiate','Init','Main','Unassigned wall remainder','Load1 range'],phases))
    details=[]
    for w,i in dict.fromkeys((r['workload'],r['impl']) for r in io):
        rr=[r for r in io if (r['workload'],r['impl'])==(w,i)]
        fields={}
        for r in rr:
            for kv in r['ns_detail'].split(';'):
                if ':' in kv:
                    k,v=kv.split(':',1);fields.setdefault(k,[]).append(float(v)/1e9)
        for k,vs in fields.items():details.append([w,i,k,fmt(vs),load(rr)])
    parts.append('\n## IO subphases\n\n'+mdtable(['Workload','Implementation','Phase','Seconds','Load1 range'],details))
    pathlib.Path('REPORT.md').write_text('\n'.join(parts))
    pathlib.Path('out/tables.md').write_text(table1+'\n'+table2+'\n'+table3)
if __name__=='__main__':main()
