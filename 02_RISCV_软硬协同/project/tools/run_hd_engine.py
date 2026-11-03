from pathlib import Path
import subprocess,sys,json,time,hashlib,shutil,importlib.util,argparse
import numpy as np
from PIL import Image
R=Path(__file__).resolve().parents[1];P=R/'structure/board_r6/project';M=Path('D:/modeltech_10.2c/win32')
ap=argparse.ArgumentParser();ap.add_argument('--ink',type=int,choices=[0,1,2],default=0);ap.add_argument('--cases',type=int,default=4);ap.add_argument('--output',type=Path);a=ap.parse_args();O=(a.output or R/('evidence/hd_neon' if a.ink==2 else 'evidence/hd_ink' if a.ink else 'evidence/hd_pp')).resolve();O.mkdir(parents=True,exist_ok=True);V=O/'vectors';V.mkdir(exist_ok=True)
model=['PixelPoster','TinyInk','TinyNeon'][a.ink];prefix=['pixelposter','tinyink','tinyneon'][a.ink]
spec=importlib.util.spec_from_file_location('ref',R/f'model/{model}/src/integer_reference.py');ref=importlib.util.module_from_spec(spec);spec.loader.exec_module(ref);z=np.load(R/f'model/{model}/fpga/{prefix}_weights_int8.npz')
def hx(path,x,rgb=False):
 x=np.asarray(x)
 if rgb:x=x.astype(np.uint32);x=(x[...,0]<<16)|(x[...,1]<<8)|x[...,2]
 path.write_text(''.join(f'{int(v):0{6 if rgb else 2}x}\n' for v in x.ravel()))
for c in range(a.cases):
 if c<2:
  x=np.fromfile(R/f'model/{model}/golden/test{c}/input_rgb_u8_hwc.bin',np.uint8).reshape(480,640,3)
  x=np.array(Image.fromarray(x).resize((1280,720),Image.Resampling.BILINEAR))
 else:x=np.full((720,1280,3),0 if c==2 else 255,np.uint8)
 low=ref.preprocess(x) if a.ink else ref.pool8(x);out,layers,_=ref.infer_low(low,z,True)
 y=ref.expand_rgb(out) if a.ink else out.repeat(8,0).repeat(8,1)
 hx(V/f'case{c}_input.hex',x,True);hx(V/f'case{c}_output.hex',y,True);hx(V/f'case{c}_pool.hex',low.repeat(3,2) if a.ink else low,True)
 for l in range(3):hx(V/f'case{c}_l{l}.hex',layers[l])
for n in ['hd_weights.mem','hd_bias.mem']:shutil.copy2(P/n,O/n)
bench=(R/'verification/tb_hd_engine.sv').read_text().replace("done_model!=(INK ? 32'h54493031 : 32'h50503031)","done_model!=(INK==2 ? 32'h544e3031 : INK ? 32'h54493031 : 32'h50503031)")
(O/'tb.sv').write_text(bench)
S=[R/'rtl/hd720_fused_core.sv',R/'rtl/dualstyle_frame_engine.sv',R/'structure/integration/ab05_rgbx_axi_reader_prefetch.sv',R/'structure/integration/ab05_native_writer_srl.sv',O/'tb.sv']
def run(n,cmd):
 with (O/(n+'.log')).open('w') as f:q=subprocess.run([str(v) for v in cmd],cwd=O,stdout=f,stderr=subprocess.STDOUT)
 s=(O/(n+'.log')).read_text(errors='replace');assert q.returncode==0 and '** Error:' not in s and '** Fatal:' not in s,(n,s[-6000:]);return s
run('vlib',[M/'vlib.exe','work']);run('compile',[M/'vlog.exe','-sv',*S]);receipts=[];t=time.monotonic()
for name,fault,cases in [('goldens',0,a.cases),('rresp',1,1),('bresp',2,1)]:
 run('opt_'+name,[M/'vopt.exe','work.tb',f'-gFAULT={fault}',f'-gCASES={cases}',f'-gINK={a.ink}','+acc','-o',name])
 s=run(name,[M/'vsim.exe','-c','work.'+name,'-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f']);rr=[v for v in s.splitlines() if 'HD720_' in v and 'PASS' in v];assert rr;receipts+=rr;print('\n'.join(rr),flush=True)
(O/'RESULTS.json').write_text(json.dumps(dict(status='PASS',hardware_accessed=False,model=model,cases=a.cases,WH=[1280,720],reference='Independent NumPy native-size extension of unchanged 640x480-trained C weights; C did not supply native720 goldens',seconds=time.monotonic()-t,receipts=receipts,source_sha256={p.relative_to(R).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in S}),indent=2))
