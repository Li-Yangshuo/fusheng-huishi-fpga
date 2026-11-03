from pathlib import Path
import hashlib,json,sys
R=Path(__file__).resolve().parent
m=json.loads((R/'MANIFEST_SHA256.json').read_text(encoding='utf-8'))
bad=[]
for e in m['files']:
 p=R/e['path']
 if not p.is_file() or p.stat().st_size!=e['bytes'] or hashlib.sha256(p.read_bytes()).hexdigest()!=e['sha256']:bad.append(e['path'])
expected={e['path'] for e in m['files']}|{'MANIFEST_SHA256.json'}
actual={p.relative_to(R).as_posix() for p in R.rglob('*') if p.is_file() and '__pycache__' not in p.parts}
extra=sorted(actual-expected);missing=sorted(expected-actual)
print(json.dumps({'status':'PASS' if not bad and not missing and not extra else 'FAIL','files':len(m['files']),'mismatch':bad,'missing':missing,'extra':extra},ensure_ascii=False))
sys.exit(bool(bad or missing or extra))
