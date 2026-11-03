from pathlib import Path
import subprocess,json,hashlib
R=Path(__file__).resolve().parents[1];O=R/'evidence/r8_control';O.mkdir(parents=True,exist_ok=True);M=Path('D:/modeltech_10.2c/win32')
S=[R/'rtl/r8_control.sv',R/'verification/tb_r8_control.sv']
for n,cmd in [('vlib',[M/'vlib.exe','work']),('compile',[M/'vlog.exe','-sv',*S]),('opt',[M/'vopt.exe','work.tb_r8_control','-o','unit']),('simulate',[M/'vsim.exe','-c','work.unit','-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f'])]:
 with (O/f'{n}.log').open('w') as f:q=subprocess.run(list(map(str,cmd)),cwd=O,stdout=f,stderr=subprocess.STDOUT)
 s=(O/f'{n}.log').read_text(errors='replace');assert q.returncode==0 and '** Fatal:' not in s and '** Error:' not in s,(n,s[-4000:])
assert 'R8_CONTROL PASS' in s
d={'status':'PASS','hardware_accessed':False,'receipts':[v for v in s.splitlines() if 'R8_CONTROL PASS' in v],'source_sha256':{str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in S}}
(O/'RESULTS.json').write_text(json.dumps(d,indent=2));print(d['receipts'])
