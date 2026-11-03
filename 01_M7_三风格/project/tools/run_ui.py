from pathlib import Path
import subprocess,json,numpy as np,hashlib
from PIL import Image
R=Path(__file__).resolve().parents[1];O=R/'evidence/ui';O.mkdir(exist_ok=True);M=Path('D:/modeltech_10.2c/win32')
rows=json.loads((R/'verification/demo_glyphs.json').read_text());all_expected=[]
for fps in [298,301,0,999]:
 image=np.full((160,360),0x335577,np.uint32);image[8:56,8:152]=0
 for line,text in enumerate(['1280X720',f'FPS:{fps//10:02}.{fps%10}']):
  for col,ch in enumerate(text):
   for gy,row in enumerate(rows[ch]):
    for gx,b in enumerate(row):
     if b=='1':image[16+16*line+gy*2:18+16*line+gy*2,16+16*col+gx*2:18+16*col+gx*2]=0xffffff
 all_expected.extend(image.ravel())
(O/'osd_expected.hex').write_text(''.join(f'{int(v):06x}\n' for v in all_expected))
S=[R/'rtl'/n for n in ['demo_key.sv','demo_fps.sv','demo_osd.sv']]+[R/'verification/tb_demo_ui.sv',R/'verification/tb_fps_decimal.sv'];receipts=[]
commands=[('vlib',[M/'vlib.exe','work']),('compile',[M/'vlog.exe','-sv',*S])]
for top in ['tb_key_fps','tb_osd','tb_fps_decimal']:
 commands += [('opt_'+top,[M/'vopt.exe','work.'+top,'+acc','-o',top+'_opt']),('run_'+top,[M/'vsim.exe','-c','work.'+top+'_opt','-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f'])]
for n,cmd in commands:
 with (O/(n+'.log')).open('w') as f:q=subprocess.run([str(v) for v in cmd],cwd=O,stdout=f,stderr=subprocess.STDOUT)
 s=(O/(n+'.log')).read_text(errors='replace');assert q.returncode==0 and '** Error:' not in s and '** Fatal:' not in s,(n,s[-5000:]);receipts += [v for v in s.splitlines() if ' PASS ' in v]
actual=np.array([int(v,16) for v in (O/'osd_actual.hex').read_text().split()],np.uint32);assert np.array_equal(actual,all_expected)
im=actual[:57600].reshape(160,360);Image.fromarray(np.stack([(im>>16)&255,(im>>8)&255,im&255],-1).astype(np.uint8)).save(O/'OSD_actual.png')
(O/'RESULTS.json').write_text(json.dumps(dict(status='PASS',receipts=receipts,hardware_accessed=False,source_sha256={p.relative_to(R).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in S}),indent=2));print(receipts)
