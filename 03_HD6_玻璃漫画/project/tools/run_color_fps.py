from pathlib import Path
import numpy as np,json,subprocess,hashlib,argparse
R=Path(__file__).resolve().parents[1];P=R/'structure/board_r6/project';M=Path('D:/modeltech_10.2c/win32')
ap=argparse.ArgumentParser();ap.add_argument('--output',type=Path,default=R/'evidence/color_fps');a=ap.parse_args();O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
def hx(p,v,width):p.write_text(''.join(f'{int(x):0{width}x}\n' for x in np.asarray(v).reshape(-1)))
all_in=[];all_out=[];gains_r=[];gains_b=[];counts=[];ar=ab=256;est=False
colors=[(64,128,64),(64,128,64),(0,0,0),(255,0,0),(48,144,48),(128,128,128),None,(255,255,255),(96,128,64),(1,2,1),(128,64,192),(128,128,128)]
rng=np.random.default_rng(20261031)
for f,color in enumerate(colors):
 x=np.tile(color,(3072,1)).astype(np.int64) if color else rng.integers(8,241,(3072,3)).astype(np.int64)
 gains_r.append(ar);gains_b.append(ab);y=np.clip((x*np.array([ar,256,ab])+128)>>8,0,255)
 all_in.extend((x[:,0]<<16)|(x[:,1]<<8)|x[:,2]);all_out.extend((y[:,0]<<16)|(y[:,1]<<8)|y[:,2])
 mn=x.min(1);mx=x.max(1);mask=(mn>=8)&(mx>=48)&(mx<=240)&(mx<=3*mn);counts.append(int(mask.sum()));s=x[mask].sum(0)
 if mask.sum()>=1024 and s[0] and s[2]:
  tr=int(np.clip((int(s[1])*256+int(s[0])//2)//int(s[0]),128,1024));tb=int(np.clip((int(s[1])*256+int(s[2])//2)//int(s[2]),128,1024))
  def smooth(old,target):return target if not est else old+(target-old+2)//4 if target>=old else old-(old-target+2)//4
  ar=smooth(ar,tr);ab=smooth(ab,tb);est=True
hx(O/'color_inputs.hex',all_in,6);hx(O/'color_expected.hex',all_out,6);hx(O/'color_r.hex',gains_r,3);hx(O/'color_b.hex',gains_b,3);hx(O/'color_counts.hex',counts,5)
S=[R/'rtl/pp2_white_balance.sv',R/'rtl/pp2_fps_meter.sv',R/'verification/tb_color_fps.sv']
def run(n,cmd):
 with (O/f'{n}.log').open('w') as f:q=subprocess.run([str(v) for v in cmd],cwd=O,stdout=f,stderr=subprocess.STDOUT)
 s=(O/f'{n}.log').read_text(errors='replace');assert q.returncode==0 and '** Error:' not in s and '** Fatal:' not in s,(n,s[-5000:]);return s
run('vlib',[M/'vlib.exe','work']);run('compile',[M/'vlog.exe','-sv',*S]);receipts=[]
for top in ['tb','tb_fps']:
 run('opt_'+top,[M/'vopt.exe','work.'+top,'+acc','-o',top+'_opt']);s=run('run_'+top,[M/'vsim.exe','-c','work.'+top+'_opt','-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f']);r=[v for v in s.splitlines() if ' PASS ' in v];assert len(r)==1;receipts+=r;print(r[0],flush=True)
(O/'RESULTS.json').write_text(json.dumps(dict(status='PASS',scope='12-frame independent NumPy white balance RGB/marks/gains reference; accelerated-timebase FPS windows. Not physical color calibration.',receipts=receipts,source_sha256={p.relative_to(R).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in S},hardware_accessed=False),indent=2))
