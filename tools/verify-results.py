#!/usr/bin/env python3
"""Verify the published compact data without compiler sources or Julia."""
from pathlib import Path
import csv,collections,hashlib,json,os
ROOT=Path(__file__).resolve().parent.parent
os.chdir(ROOT)
inventory=json.loads(Path('PUBLICATION.json').read_text())
for item in inventory['result_files']:
    assert hashlib.sha256(Path(item['path']).read_bytes()).hexdigest()==item['sha256'],item['path']
expected={'table1/results.csv':645,'table2/io.csv':120,'table3/results.csv':340,'table3-io/io.csv':510,'startup/startup.csv':25,'opt.csv':110}
for rel,n in expected.items():
    rows=list(csv.DictReader(open(Path('out')/rel)))
    assert len(rows)==n,(rel,len(rows),n)
    groups=collections.defaultdict(list)
    for row in rows:
        assert 'equivalent' not in row or row['equivalent']=='true',(rel,row)
        if rel=='opt.csv':key=(row['kind'],row['variant'])
        elif rel.startswith('startup'):key=(row['what'],)
        elif 'case' in row:key=(row['label'],row['case'],row['cmd'],row['impl'])
        else:key=(row['label'],row['workload'],row['impl'])
        groups[key].append(row)
    assert all(len(v)==5 and {r['round'] for r in v}=={'1','2','3','4','5'} for v in groups.values()),rel
audit=json.loads(Path('out/audit.json').read_text())
assert not audit['issues']
assert sum(x['passed'] for x in audit['gates'].values())==430
print('Verified checksums, 1,750 measurement rows, five-round groups and the recorded 430-gate audit.')
