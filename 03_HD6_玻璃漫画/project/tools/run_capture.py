from pathlib import Path
import subprocess,json,hashlib
R=Path(__file__).resolve().parents[1];O=R/'evidence/capture';O.mkdir(exist_ok=True);M=Path('D:/modeltech_10.2c/win32')
S=[R/'rtl/ab720_capture_guard.sv',R/'verification/tb_hd_capture.sv']
for n,cmd in [('vlib',[M/'vlib.exe','work']),('compile',[M/'vlog.exe','-sv',*S]),('opt',[M/'vopt.exe','work.tb_hd_capture','+acc','-o','capture']),('simulate',[M/'vsim.exe','-c','work.capture','-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f'])]:
 with (O/(n+'.log')).open('w') as f:q=subprocess.run([str(v) for v in cmd],cwd=O,stdout=f,stderr=subprocess.STDOUT)
 s=(O/(n+'.log')).read_text(errors='replace');assert q.returncode==0 and '** Error:' not in s and '** Fatal:' not in s,(n,s[-4000:])
receipts=[v for v in s.splitlines() if 'HD720_CAPTURE PASS' in v];assert receipts
(O/'RESULTS.json').write_text(json.dumps(dict(status='PASS',hardware_accessed=False,receipts=receipts,source_sha256={p.relative_to(R).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in S}),indent=2));print(receipts)
