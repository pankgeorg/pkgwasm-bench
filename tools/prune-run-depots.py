#!/usr/bin/env python3
"""Remove reproducible depot payloads only after all runtime batches and the audit."""
import pathlib,os,json,subprocess
R=pathlib.Path(__file__).resolve().parent.parent
os.chdir(R)
assert 'All scheduled benchmark batches finished.' in pathlib.Path('out/controller.log').read_text()
subprocess.run(['python3','harness/audit.py'],check=True,stdout=open('out/audit-before-prune.json','w'))
root=R/'out'
# Retain the complete base correctness states so further targeted runs can use
# the existing live stock reference. Keep builds and all module artifacts too.
protected={'validate','raw','build-env','variants','bench-variants','code-compare','flag-probes','tmp','relocation-cache','sentinel','maintenance'}
payloads={'registries','packages','artifacts','compiled','scratchspaces'}
targets=[]
for top in root.iterdir():
    if not top.is_dir() or top.name in protected or top.is_symlink():continue
    for here,dirs,files in os.walk(top,topdown=True,followlinks=False):
        p=pathlib.Path(here)
        if p.name=='depot':
            for child in list(dirs):
                if child not in payloads:continue
                q=p/child
                assert q.is_relative_to(root) and q.resolve().is_relative_to(root),str(q)
                targets.append(q);dirs.remove(child)
        dirs[:]=[d for d in dirs if d not in {'.git','node_modules'}]
manifest={'reason':'Reproducible per-run depot payloads; captured results, CSV, logs, hashes, cache checkpoints, projects, fixtures, modules and full out/validate retained.','paths':[str(p.relative_to(R)) for p in targets]}
pathlib.Path('out/pruned-depots.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Removing',len(targets),'generated payload trees; full base references remain.',flush=True)
for i in range(0,len(targets),100):
    subprocess.run(['rm','-rf','--',*[str(p) for p in targets[i:i+100]]],check=True)
print('Prune complete.',flush=True)
subprocess.run(['du','-x','-B1','--max-depth=1','.'],check=True,stdout=open('out/disk-usage-after-prune.txt','w'))
subprocess.run(['df','-B1','.'],check=True,stdout=open('out/disk-free-after-prune.txt','w'))
