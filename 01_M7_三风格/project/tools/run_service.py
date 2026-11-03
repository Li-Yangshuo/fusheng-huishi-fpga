from pathlib import Path
import subprocess,json,hashlib,time,argparse,shutil
R=Path(__file__).resolve().parents[1];P=R/'structure/board_r6/project';M=Path('D:/modeltech_10.2c/win32')
ap=argparse.ArgumentParser();ap.add_argument('--style',type=int,choices=[0,1,2],default=2);ap.add_argument('--output',type=Path,default=R/'evidence/service');a=ap.parse_args();O=a.output.resolve();O.mkdir(parents=True,exist_ok=True)
(O/'vectors').mkdir(exist_ok=True)
for n in ['case0_input.hex','case0_output.hex','case1_input.hex','case1_output.hex']:shutil.copy2(R/'evidence/hd_pp/vectors'/n,O/'vectors'/n)
for n in ['hd_weights.mem','hd_bias.mem']:shutil.copy2(P/n,O/n)
import sys,importlib.util,numpy as np
spec=importlib.util.spec_from_file_location('ink_reference',R/'model/TinyInk/src/integer_reference.py');ref=importlib.util.module_from_spec(spec);spec.loader.exec_module(ref)
z=np.load(R/'model/TinyInk/fpga/tinyink_weights_int8.npz')
for c in range(2):
 x=np.array([int(v,16) for v in (R/f'evidence/hd_pp/vectors/case{c}_input.hex').read_text().split()],np.uint32)
 rgb=np.stack([(x>>16)&255,(x>>8)&255,x&255],-1).astype(np.uint8).reshape(720,1280,3)
 y=ref.expand_rgb(ref.infer_low(ref.preprocess(rgb),z));y=y.astype(np.uint32)
 (O/f'vectors/ink{c}_output.hex').write_text(''.join(f'{int(v):06x}\n' for v in ((y[...,0]<<16)|(y[...,1]<<8)|y[...,2]).ravel()))
tb='tb_service_switch' if a.style==2 else 'tb_service'
S=[R/'rtl/hd720_fused_core.sv',R/'rtl/dualstyle_frame_engine.sv']+[R/'structure/integration'/n for n in ['a_b_video_renderer_shared.sv','ab05_video_pipeline_shared_r3.sv','ab05_video_ownership.sv','ab05_camera_selector.sv','ab05_capture_ingress.sv','ab05_async_stream.sv','ab05_job_watchdog.sv','ab05_rgbx_axi_reader_prefetch.sv','ab05_axi_read_rr3.sv','ab05_axi_write_rr2.sv','ab05_native_writer_srl.sv']]+[R/f'verification/{tb}.sv']
def run(n,cmd):
 with (O/f'{n}.log').open('w') as f:q=subprocess.run([str(v) for v in cmd],cwd=O,stdout=f,stderr=subprocess.STDOUT)
 s=(O/f'{n}.log').read_text(errors='replace');assert q.returncode==0 and '** Error:' not in s and '** Fatal:' not in s,(n,s[-6000:]);return s
run('vlib',[M/'vlib.exe','work']);run('compile',[M/'vlog.exe','-sv',*S]);run('opt',[M/'vopt.exe','work.'+tb,f'-gSTYLE={a.style}','-gFRAMES=12','+acc','-o','service'])
t=time.monotonic();s=run('simulate',[M/'vsim.exe','-c','work.service','-do','onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f']);receipts=[v for v in s.splitlines() if 'DUALSTYLE_SERVICE' in v or 'HD720_RATE' in v];assert 'DUALSTYLE_SERVICE PASS' in s
res=dict(status='PASS',style=a.style,input_fps=30,frames=12,seconds=round(time.monotonic()-t,3),hardware_accessed=False,scope='Actual service wrapper, ownership, camera selector/ingress, native720 fused engine, dual native DDR readers, shared read/write arbitration and watchdogs; memory BFM with stalls; 30Hz RGB input and 60Hz consumer requests. Does not include PHY, HDMI timing/CDC or CPU.',source_sha256={str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in S},receipts=receipts)
(O/'RESULTS.json').write_text(json.dumps(res,indent=2));print('\n'.join(receipts),flush=True)
