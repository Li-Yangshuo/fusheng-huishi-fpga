from pathlib import Path
import argparse,datetime,hashlib,json,subprocess,time
ROOT=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser();ap.add_argument('--bin',default='D:/modeltech_10.2c/win32');ap.add_argument('--name',default=datetime.datetime.now().strftime('native_%Y%m%d_%H%M%S'));args=ap.parse_args()
if Path(args.name).name!=args.name:raise SystemExit('simple new name required')
out=ROOT/'runs'/args.name;out.mkdir(parents=True,exist_ok=False)
sources=sorted((ROOT/'rtl').glob('*.sv'))+[ROOT/'tests/tb_dual_preview_hdmi_native.sv']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
r={'status':'RUNNING','scope':'full 960x540 dual behavior streams in 2200x1125 raster; no NN/physical DDR evidence',
   'source_SHA256':{str(p.relative_to(ROOT)):sha(p) for p in sources},'commands':[],
   'board_verified':False,'PNR_timing_signed_off':False,'DDR_service_gap_measured':False,
   'axi_ns':10,'pixel_ns':6.734,'view':[960,540],'timing_total':[2200,1125]}
start=time.monotonic();b=Path(args.bin)
try:
 stages=[('library',[str(b/'vlib.exe'),'work']),('compile',[str(b/'vlog.exe'),'-sv',*map(str,sources)]),
         ('native_dual',[str(b/'vsim.exe'),'-c','work.tb_dual_preview_hdmi_native','-do',
          'onerror {quit -code 1 -f};onbreak {quit -code 1 -f};run -all;quit -code 0 -f'])]
 for label,cmd in stages:
  z=subprocess.run(cmd,cwd=out,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,encoding='utf-8',errors='replace',timeout=1800)
  log=out/(label+'.log');log.write_text(z.stdout,encoding='utf-8')
  r['commands'].append({'stage':label,'command':cmd,'returncode':z.returncode,'log_SHA256':sha(log)})
  if z.returncode or '** Error:' in z.stdout or '** Fatal:' in z.stdout:raise RuntimeError(label+' failed: '+str(log))
  if label=='native_dual':
   receipts=[line for line in z.stdout.splitlines() if 'DUAL_NATIVE PASS ' in line]
   if len(receipts)!=1:raise RuntimeError('missing unique native PASS')
   r['receipts']=receipts
 trace=out/'display_trace.csv'
 r['trace_SHA256']=sha(trace);r['frame_trace']=[x for x in trace.read_text().splitlines() if x.startswith('FRAME')]
 r['status']='PASS'
except Exception as e:r.update(status='FAIL',error=str(e))
r['seconds']=round(time.monotonic()-start,3);(out/'result.json').write_text(json.dumps(r,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'status':r['status'],'result':str(out/'result.json'),'receipts':r.get('receipts'),'error':r.get('error'),'seconds':r['seconds']},ensure_ascii=False))
if r['status']!='PASS':raise SystemExit(1)
