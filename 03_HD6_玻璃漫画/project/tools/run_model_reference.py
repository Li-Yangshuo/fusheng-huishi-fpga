from pathlib import Path
import subprocess,sys,json,hashlib
R=Path(__file__).resolve().parents[1];M=R/'model/TinyGlass';O=R/'evidence/model_reference';O.mkdir(exist_ok=True)
q=subprocess.run([sys.executable,'-X','utf8',M/'src/verify_release.py'],capture_output=True,text=True)
(O/'verify.log').write_text(q.stdout+q.stderr);assert q.returncode==0,q.stdout+q.stderr
result=json.loads(q.stdout);assert result['status']=='PASS'
files=[M/v['path'] for v in json.loads((M/'MANIFEST.json').read_text())['files']]+[M/'MANIFEST.json']
result.update(hardware_accessed=False,scope='Original C640x480 model manifest, NPZ/BIN/HEX and two golden frames including every layer, exact independent NumPy',source_sha256={p.relative_to(R).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
(O/'RESULTS.json').write_text(json.dumps(result,indent=2));print(q.stdout)
