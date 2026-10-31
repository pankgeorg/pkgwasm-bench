#!/usr/bin/env python3
import csv,collections,pathlib,tomllib,json,subprocess,hashlib
ROOT=pathlib.Path(__file__).resolve().parent.parent
import os
os.chdir(ROOT)
issues=[];summary={}
for name in ['table1/results.csv','table2/io.csv','table3/results.csv','table3-io/io.csv','startup/startup.csv','opt.csv']:
 p=pathlib.Path('out')/name
 if not p.exists():issues.append(name+': missing');continue
 rows=list(csv.DictReader(p.open()));summary[name]=len(rows)
 groups=collections.defaultdict(list)
 for row in rows:
  if None in row:issues.append(name+': malformed row')
  if 'equivalent' in row and row['equivalent']!='true':issues.append(name+': equivalence failure '+str(row))
  if name=='opt.csv':key=(row['kind'],row['variant'])
  elif name.startswith('startup'):key=(row['what'],)
  elif 'case' in row:key=(row['label'],row['case'],row['cmd'],row['impl'])
  else:key=(row['label'],row['workload'],row['impl'])
  groups[key].append(row)
 for k,rs in groups.items():
  if len(rs)!=5 or set(r['round'] for r in rs)!={'1','2','3','4','5'}:issues.append(name+': incomplete group '+str(k)+' n='+str(len(rs)))
  if name=='opt.csv' and len(set(r['size_bytes'] for r in rs))!=1:issues.append('optimizer output sizes vary: '+str(k))
expected_counts={'table1/results.csv':645,'table2/io.csv':120,'table3/results.csv':340,'table3-io/io.csv':510,'startup/startup.csv':25,'opt.csv':110}
for name,n in expected_counts.items():
 if summary.get(name)!=n:issues.append(f'{name}: expected {n} accepted rows, got {summary.get(name)}')
gate_counts={}
paths={'out/validate/gates.toml':48,'out/io-validate/gates.toml':24,'out/sweep-eq/O3/gates.toml':16}
paths['out/sweep-eq/O3-keepalive/gates.toml']=16
paths['out/sweep-io-eq/O3-keepalive/gates.toml']=3
variants=['O3conv','O3x2','Os','gufaopt','tmerge','atr','rut','mono','gccombo','tnh','node-noliftoff','node-liftoffonly','node-nodyntier','node-nolazy','node-semi32','node-semi64','node-semi128']
for v in variants:
 paths[f'out/sweep-eq/{v}/gates.toml']=16
 paths[f'out/sweep-io-eq/{v}/gates.toml']=3
for p,n in paths.items():
 gate=tomllib.load(open(p,'rb')) if pathlib.Path(p).exists() else {}
 gate_counts[p]={'count':len(gate),'passed':sum(gate.values())}
 if len(gate)!=n or not all(gate.values()):issues.append(f'{p}: expected {n} passing gates, got {gate_counts[p]}')
instrumentation={}
def checked(p):
 return dict(line.split('=',1) for line in p.read_text().splitlines() if '=' in line and not line.startswith('ns'))
for w in ['tar','walk','walkdir','lines','read','cp','toml','dir']:
 actual=pathlib.Path(f'out/table2/counts/{w}.txt');reference=pathlib.Path(f'out/ioref/{w}.txt')
 ok=actual.exists() and reference.exists() and checked(actual)==checked(reference)
 instrumentation[w]=ok
 if not ok:issues.append('instrumentation differs: '+w)
cache_checks=[]
for r in range(1,6):
 for c in ['M4-warm','M4-noop']:
  d=pathlib.Path(f'out/table1/runs/M4/r{r}/wasm/{c}/out')
  try:
   before=tomllib.load(open(d/'cache-before.toml','rb'));after=tomllib.load(open(d/'cache-after.toml','rb'))
   ok=before==after and any(k.endswith('.idx') for k in before)
  except FileNotFoundError:ok=False
  cache_checks.append({'path':str(d),'unchanged':ok})
  if not ok:issues.append('M4 cache checkpoint invalid: '+str(d))
fingerprint=json.loads(pathlib.Path('out/base-validation-inputs.json').read_text())
for p,h in fingerprint.items():
 if pathlib.Path(p).is_file() and hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()!=h:issues.append('validated input changed: '+p)
expected={'WasmCodegen.jl':'5d4b68e0d5eba32ee901d06e81c525efaa2d8666','PkgWasm.jl':'9fe2f5ab458abba7b4d4f3de4aa86e64f97d67b5','WasmBuilder.jl':'4b64c589478e8769209a3870488f65c77a751f6c','IRStructurizer.jl':'ab056b165d5038229e2dd700df932b8a9704e03b'}
for n,h in expected.items():
 got=subprocess.check_output(['git','-C','src/'+n,'rev-parse','HEAD'],text=True).strip()
 dirty=subprocess.check_output(['git','-C','src/'+n,'status','--porcelain'],text=True).strip()
 if got!=h or dirty:issues.append('source changed: '+n+' '+got+' '+dirty)
result={'rows':summary,'gates':gate_counts,'instrumentation':instrumentation,'base_m4_cache':cache_checks,'issues':issues}
pathlib.Path('out/audit.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
raise SystemExit(bool(issues))
