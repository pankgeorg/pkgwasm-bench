#!/usr/bin/env python3
"""Single controller: untimed gates first; one timed batch at a time; all logs local."""
import csv, json, os, pathlib, statistics, subprocess, time, tomllib, traceback, hashlib, sys
R=pathlib.Path(__file__).resolve().parent.parent
os.chdir(R)
JL=os.environ['JULIA']; NODE=os.environ['NODE']; CPU=os.environ['BENCH_CPUSET']
LOG=R/'out/logs'; LOG.mkdir(exist_ok=True)
CASES=['M4-cold','M4-warm','M4-noop']+list(tomllib.load(open('fixtures/scenarios.toml','rb')))
WORK=['tar','walk','walkdir','lines','read','cp','toml','dir']
OPT={'O3':['-O3'],'O4':['-O4'],'O3conv':['-O3','--converge'],'O3x2':['-O3','-O3'],'Os':['-Os'],'gufaopt':['-O3','--gufa-optimizing'],'tmerge':['--type-merging','-O3'],'atr':['--abstract-type-refining','-O3'],'rut':['--remove-unused-types','-O3'],'mono':['--monomorphize','-O3'],'gccombo':['--abstract-type-refining','--type-merging','--remove-unused-types','-O3','--gufa-optimizing'],'tnh':['-O3','-tnh']}
NODEF={'noliftoff':'--no-liftoff','liftoffonly':'--liftoff-only','nodyntier':'--no-wasm-dynamic-tiering','nolazy':'--no-wasm-lazy-compilation','semi32':'--max-semi-space-size=32','semi64':'--max-semi-space-size=64','semi128':'--max-semi-space-size=128'}
def status(s):
    s=time.strftime('%Y-%m-%d %H:%M:%S UTC: ',time.gmtime())+s
    print(s,flush=True)
    with open('STATUS.md','a') as f:f.write('\n'+s+'\n')
def run(name, args, timed=False, timeout=10800):
    status(('TIMED ' if timed else '')+name)
    if timed or name.startswith('opt-'):
        with open(LOG/(name+'.load.txt'),'w') as lf:
            subprocess.run(['uptime'],stdout=lf)
            subprocess.run(['bash','-c','top -bn1 | head -20'],stdout=lf)
    cmd=([ 'taskset','-c',CPU] if timed else [])+list(map(str,args))
    with open(LOG/(name+'.log'),'w') as f:
        f.write('COMMAND '+repr(cmd)+'\n');f.flush()
        try: p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=timeout); rc=p.returncode
        except subprocess.TimeoutExpired:rc=124
    status(name+' exit '+str(rc))
    if timed and rc:raise RuntimeError(name+' failed; no later timed batch will start')
    return rc

def pkg(sub,out,impls,wasm='out/pkgwasm.wasm',variant=None,cases=None,label='base',baseline='out/validate',timed=False):
    args=[JL,'--startup-file=no','harness/pkgbench.jl',sub,'--out',out,'--wasm',wasm]
    if sub!='startup':args+=['--impls',','.join(impls),'--baseline',baseline]
    if timed:args+=['--rounds','5']
    if sub=='time':args+=['--label',label,'--quiet-wait','0']
    if sub=='time' and label=='node-nolazy':args+=['--nodeflags','--import '+str(R/'tools/compile-keepalive.mjs')]
    if variant:args+=['--variant',variant]
    args+=cases or []
    return run('pkg-'+sub+'-'+label,args,timed)
def io(sub,out,impls,wasm='out/bench-variants/O3.wasm',variant=None,work=None,label='base',timed=False):
    args=[JL,'--startup-file=no','harness/iobench.jl',sub,'--out',out,'--wasm',wasm]
    if sub!='count':args+=['--impls',','.join(impls)]
    if timed:args+=['--rounds','5']
    if sub=='time':args+=['--label',label,'--quiet-wait','0']
    if sub=='time' and label=='node-nolazy':args+=['--nodeflags','--import '+str(R/'tools/compile-keepalive.mjs')]
    if variant:args+=['--variant',variant]
    args+=work or []
    return run('io-'+sub+'-'+label,args,timed)
def gates(out):
    p=pathlib.Path(out)/'gates.toml';return tomllib.load(open(p,'rb')) if p.exists() else {}
def optimize():
    stats=list(csv.DictReader(open('out/opt.csv'))) if pathlib.Path('out/opt.csv').exists() else []
    fingerprints={k:hashlib.sha256(pathlib.Path(f'out/raw/{k}.raw.wasm').read_bytes()).hexdigest() for k in ['pkgwasm','bench']}
    fpfile=pathlib.Path('out/opt-inputs.json')
    oldfp=json.loads(fpfile.read_text()) if fpfile.exists() else fingerprints
    stats=[r for r in stats if oldfp.get(r['kind'])==fingerprints.get(r['kind'])]
    fpfile.write_text(json.dumps(fingerprints,indent=2))
    def save():
        with open('out/opt.csv','w') as f:
            w=csv.DictWriter(f,fieldnames=list(stats[0]) if stats else ['kind']);w.writeheader();w.writerows(stats)
    for n, flags in OPT.items():
        for kind,d in [('pkgwasm','variants'),('bench','bench-variants')]:
            raw=pathlib.Path(f'out/raw/{kind}.raw.wasm')
            if not raw.exists():continue
            dest=pathlib.Path('out')/d;dest.mkdir(exist_ok=True)
            for r in range(1,6):
                if any(x['kind']==kind and x['variant']==n and str(x['round'])==str(r) for x in stats):continue
                out=dest/(n+'.wasm'); tf=dest/f'{n}-r{r}.time'
                rc=run(f'opt-{kind}-{n}-r{r}',['/usr/bin/time','-f','%e %M','-o',tf,'tools/wasmopt.sh',raw,out,*flags])
                if rc:break
                wall,rss=tf.read_text().strip().split()[-2:]
                load1=pathlib.Path('/proc/loadavg').read_text().split()[0]
                stats.append(dict(kind=kind,variant=n,round=r,wall_s=wall,maxrss_kib=rss,size_bytes=out.stat().st_size,flags=' '.join(flags),load1=load1))
                save()
    with open('out/opt.csv','w') as f:
        w=csv.DictWriter(f,fieldnames=list(stats[0]) if stats else ['kind']);w.writeheader();w.writerows(stats)

def code_section(p):
    b=pathlib.Path(p).read_bytes();i=8
    def leb(i):
        x=0;shift=0
        while True:
            v=b[i];i+=1;x|=(v&127)<<shift
            if v<128:return x,i
            shift+=7
    while i<len(b):
        kind=b[i];n,j=leb(i+1)
        if kind==10:return b[j:j+n]
        i=j+n

def validation_fingerprint():
    paths=['out/pkgwasm.wasm','out/bench-variants/O3.wasm','harness/pkgbench.jl','harness/iobench.jl','runner/scenarios.jl','runner/native_pkg.jl','runner/pkgwasm.mjs','bench/BenchIO.jl','bench/native.jl','fixtures/frozen.toml','fixtures/scenarios.toml','fixtures/initial/m4/project/Manifest.toml','fixtures/initial/m4/project/Project.toml']
    fp={p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in paths}
    for p in pathlib.Path('src').iterdir():
        fp[str(p)]=subprocess.check_output(['git','-C',p,'rev-parse','HEAD'],text=True).strip()
        assert not subprocess.check_output(['git','-C',p,'status','--porcelain'],text=True).strip(),str(p)+' dirty'
    return fp

def complete_pkg(out,label,cases,impls):
    p=pathlib.Path(out)/'results.csv'
    if not p.exists():return False
    rows=[r for r in csv.DictReader(p.open()) if r['label']==label]
    expected={(str(r),c,str(i),impl) for r in range(1,6) for c in cases for i in range(1,len(([['instantiate']] if c.startswith('M4-') else tomllib.load(open('fixtures/scenarios.toml','rb'))[c]['commands']))+1) for impl in impls}
    actual=[(r['round'],r['case'],r['cmd'],r['impl']) for r in rows]
    if not rows:return False
    assert len(actual)==len(set(actual)) and set(actual)==expected and all(r['equivalent']=='true' for r in rows), 'partial/invalid timed data for '+label+'; archive and rerun the whole batch'
    return True

def main():
    resume='--resume-after-validation' in sys.argv
    if resume:
        assert json.loads(pathlib.Path('out/base-validation-inputs.json').read_text())==validation_fingerprint(),'validated inputs changed'
        assert len(gates('out/validate'))==48 and all(gates('out/validate').values())
        assert len(gates('out/io-validate'))==24 and all(gates('out/io-validate').values())
        status('Resuming timing from verified 48 Pkg and 24 IO gates; inputs unchanged.')
    else:
        # Outer operator starts this only after all three builds have finished.
        optimize()
        same=code_section('out/pkgwasm.wasm')==code_section('out/variants/O3.wasm')
        pathlib.Path('out/code-section-check.txt').write_text('identical='+str(same)+'\n')
        status('Full vs raw+O3 code sections identical='+str(same))
        pkg('validate','out/validate',['stock','native','wasm'],label='all')
        run('io-prepare',[JL,'--startup-file=no','harness/iobench.jl','prepare'])
        io('validate','out/io-validate',['native','native-warm','wasm'])
        ig=gates('out/io-validate')
        good=[w for w in WORK if all(ig.get(w+'/'+i) for i in ['native','native-warm','wasm'])]
        pathlib.Path('out/base-validation-inputs.json').write_text(json.dumps(validation_fingerprint(),indent=2))
    ig=gates('out/io-validate')
    good=[w for w in WORK if all(ig.get(w+'/'+i) for i in ['native','native-warm','wasm'])]
    g=gates('out/validate')
    # Save the equivalence-gated implementation selections for the report.
    pathlib.Path('out/gates-base.json').write_text(json.dumps(g,indent=2))
    for case in CASES:
        impls=[i for i in ['stock','native','wasm'] if g.get(case+'/'+i)]
        # Warm/noop depend on this invocation's cold keep directory.
        if case.startswith('M4-'):continue
        if impls and not (resume and complete_pkg('out/table1',case,[case],impls)):pkg('time','out/table1',impls,cases=[case],label=case,timed=True)
    mimpl=[i for i in ['stock','native','wasm'] if all(g.get(c+'/'+i) for c in CASES[:3])]
    if mimpl and not (resume and complete_pkg('out/table1','M4',CASES[:3],mimpl)):pkg('time','out/table1',mimpl,cases=CASES[:3],label='M4',timed=True)
    startupfile=pathlib.Path('out/startup/startup.csv')
    startuprows=list(csv.DictReader(startupfile.open())) if startupfile.exists() else []
    if not (resume and len(startuprows)==25):pkg('startup','out/startup',[],label='startup',timed=True)
    if good:
        io('time','out/table2',['native','native-warm','wasm'],work=good,timed=True)
        io('count','out/table2',[],work=good)
    chosen=[w for w in ['tar','walk','lines','dir','toml','read','cp'] if w in good][:3]
    pathlib.Path('out/sweep-workloads.json').write_text(json.dumps(chosen))
    # Baseline raw module gets its own complete equivalence run.
    pkg('validate','out/sweep-eq/O3',['wasm-O3'],variant='wasm-O3=out/variants/O3.wasm',label='O3')
    for name,file,flags in [(n,f'out/variants/{n}.wasm','') for n in OPT if n!='O3']+[(f'node-{n}','out/variants/O3.wasm',f) for n,f in NODEF.items()]:
        if not pathlib.Path(file).exists():continue
        if name=='node-nolazy':
            keep='--import '+str(R/'tools/compile-keepalive.mjs')
            pkg('validate','out/sweep-eq/O3-keepalive',['wasm-keepalive'],variant='wasm-keepalive=out/variants/O3.wasm::'+keep,label='O3-keepalive')
            io('validate','out/sweep-io-eq/O3-keepalive',['wasm-keepalive'],variant='wasm-keepalive=out/bench-variants/O3.wasm::'+keep,work=chosen,label='O3-keepalive')
            assert len(gates('out/sweep-eq/O3-keepalive'))==16 and all(gates('out/sweep-eq/O3-keepalive').values())
            assert len(gates('out/sweep-io-eq/O3-keepalive'))==3 and all(gates('out/sweep-io-eq/O3-keepalive').values())
            flags+=' '+keep
        v='wasm-'+name; spec=f'{v}={file}'+('::'+flags if flags else '')
        eqout='out/sweep-eq/'+name
        pkg('validate',eqout,[v],variant=spec,label=name)
        vg=gates(eqout)
        if all(vg.get(c+'/'+v) for c in CASES[:2]) and all(gates('out/sweep-eq/O3').get(c+'/wasm-O3') for c in CASES[:2]):
            pkg('time','out/table3',['wasm',v],wasm='out/variants/O3.wasm',variant=spec,cases=CASES[:2],label=name,timed=True)
        bfile='out/bench-variants/'+(name if not name.startswith('node-') else 'O3')+'.wasm'
        if chosen and pathlib.Path(bfile).exists():
            iospec=f'{v}={bfile}'+('::'+flags if flags else '')
            io('validate','out/sweep-io-eq/'+name,[v],variant=iospec,work=chosen,label=name)
            iog=gates('out/sweep-io-eq/'+name)
            wg=[w for w in chosen if iog.get(w+'/'+v)]
            if wg:io('time','out/table3-io',['wasm',v],variant=iospec,work=wg,label=name,timed=True)
    # Direct probe; no cross-process cache assumed from the earlier host.
    run('cache-probe',[NODE,'tools/cache-probe.mjs','out/variants/O3.wasm'])
    status('All scheduled benchmark batches finished. Report generation pending.')
if __name__=='__main__':
    try: main()
    except Exception:
        pathlib.Path('out/controller-error.txt').write_text(traceback.format_exc());status('Controller failed; see out/controller-error.txt');raise
